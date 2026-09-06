import Darwin
import FilaClient
import FilaFormats
import FilaLog
import FilaProtocol
import Foundation
import ObjectiveC

/// The private LaunchServices selectors, declared so Swift can send them to an
/// object whose class this build never sees. `unsafeBitCast` to an `@objc`
/// protocol is the usual way to send a known selector without a header.
@objc private protocol LSInstallWorkspace {
    func installApplication(_ url: URL, withOptions options: [String: Any]?, error: NSErrorPointer) -> Bool
    func uninstallApplication(_ identifier: String, withOptions options: [String: Any]?) -> Bool
}

/// InstallCoordination's class methods, sent to the class object itself (a
/// class receives its own `+` messages), so the same trick reaches them.
/// `installApplication:` takes a file URL and an `MIInstallOptions`.
@objc private protocol IXInstallCoordinator {
    func installApplication(_ url: URL, consumeSource: Bool, options: AnyObject?, completion: @escaping (AnyObject?, AnyObject?) -> Void)
    func uninstallAppWithBundleID(_ bundleID: String, error: NSErrorPointer) -> Bool
    func existingCoordinatorForAppWithBundleID(_ bundleID: String, error: NSErrorPointer) -> AnyObject?
}

/// One place for "install / uninstall an `.ipa`", shared by the file menu's
/// Install…, the Debug probe and the Debug self-test. It is the runtime chain
/// the platform needs, never a
/// build flag: iOS 15 installs through `LSApplicationWorkspace`; iOS 16+ stubs
/// that selector (`NSOSStatusErrorDomain -4`, "Use InstallCoordination") so the
/// call routes through `IXAppInstallCoordinator` instead. `install` tries the
/// coordinator first and falls back to the workspace, so one code path covers
/// every version Fila supports.
///
/// **Verified 2026-09-05 on iOS 26.6.1 (Dopamine rootless, no AppSync):** the
/// coordinator is reachable once the process carries
/// `com.apple.private.InstallCoordination.allowed` (the deb does), its lookup
/// and uninstall work, but the package must clear `installd`'s own
/// code-signature trust — an unsigned/ad-hoc/`custom_trust` bundle fails with
/// `MIInstallerErrorDomain Code=13 (0xe800801c)` and leaves a placeholder. That
/// trust check is exactly what AppSync Unified removes. Nothing here returns a
/// success it did not earn. See `Documentation/Roadmap.md` → IPA installation.
enum IPAInstaller {
    /// What a package install attempt did. `unsupported` is not a failure: it is
    /// the environment saying "no install API is usable here", which callers
    /// render as a skip rather than a red line.
    enum Outcome {
        case installed
        case failed(domain: String, code: Int, message: String)
        case unsupported(String)
        /// The service stopped answering; this is not cancellation or refusal.
        case timedOut

        var describe: String {
            switch self {
            case .installed: return "installed"
            case let .failed(domain, code, message): return "FAILED \(domain) \(code): \(message)"
            case let .unsupported(reason): return "unsupported: \(reason)"
            case .timedOut: return "install outcome unknown: no completion in 60s"
            }
        }

        /// installd's "I will not trust this signature" — the AppSync-shaped
        /// wall, distinct from every other failure because the fix is a
        /// device-side tool, not a Fila change.
        var isSignatureRefusal: Bool {
            guard case let .failed(domain, code, message) = self else { return false }
            return (domain == "MIInstallerErrorDomain" && code == 13)
                || message.contains("0xe800801c") || message.contains("0xe8008015")
                || message.contains("code signature")
        }
    }

    /// Install `ipa` — copied by the caller first, because the installer
    /// consumes what it is handed. Coordinator (iOS 16+) first, workspace
    /// (iOS 15) as the fallback.
    static func install(ipaAt ipa: URL, packageType: String?) async -> Outcome {
        let viaCoordinator = await installViaCoordination(ipa, packageType: packageType)
        if case .unsupported = viaCoordinator {
            let viaWorkspace = await installViaWorkspace(ipa, packageType: packageType)
            if case .unsupported = viaWorkspace { return viaCoordinator }
            return viaWorkspace
        }
        return viaCoordinator
    }

    #if DEBUG
    /// Force the workspace, for the probe's Method field. `install` above is
    /// the real per-OS chain; this exists only so the probe can isolate one API
    /// when comparing them by hand.
    static func installForcingWorkspace(_ ipa: URL, packageType: String?) async -> Outcome {
        await installViaWorkspace(ipa, packageType: packageType)
    }
    #endif

    /// What the Install… card says about a package, read from the package
    /// itself: the bundle identifier installd will register it under (and the
    /// name of the placeholder to remove if it refuses), and a name to show.
    struct Manifest {
        var bundleID: String
        var displayName: String
    }

    /// Reads `Payload/<one>.app/Info.plist` out of the archive without
    /// extracting anything else. Read from the **staged copy** — the same
    /// bytes installd will receive — never from the original path, which can
    /// be replaced between the card and the install. Exactly one `.app` under
    /// `Payload/`: a second is not a package installd takes, and it must not be
    /// the one the card names while installd registers the other. No such
    /// member, or a plist without a bundle identifier, is the same refusal.
    static func manifest(ofIPAAt url: URL) async throws -> Manifest {
        try await Task.detached {
            let descriptor = open(url.path, O_RDONLY)
            guard descriptor >= 0 else { throw FilaFailure(code: .operationFailed, systemError: errno, path: url.path) }
            defer { close(descriptor) }
            let notAnApp = ViewerFailure.unsupportedContent(String(localized: "“\(url.lastPathComponent)” is not an app package. Choose an .ipa that contains one app."))
            let reader = try ArchiveReader(descriptor: descriptor)
            var found: Manifest?
            while let entry = try reader.next() {
                let parts = entry.declaredPath.split(separator: "/")
                guard parts.count == 3, parts[0] == "Payload", parts[1].hasSuffix(".app"), parts[2] == "Info.plist" else { continue }
                let data = try reader.data(maximumByteCount: 4 * 1024 * 1024)
                guard found == nil,
                      let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                      let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty
                else { throw notAnApp }
                let bundleName = String(parts[1])
                let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
                found = Manifest(
                    bundleID: bundleID,
                    displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? (bundleName as NSString).deletingPathExtension
                )
            }
            guard let found else { throw notAnApp }
            return found
        }.value
    }

    /// Remove an installed app (or the placeholder a refused install left).
    /// Coordinator first, workspace fallback. Nil on success; otherwise why it
    /// was refused — including for an app that is not installed, which is the
    /// answer a caller wants there.
    static func uninstall(bundleID: String) async -> String? {
        _ = dlopen("/System/Library/PrivateFrameworks/InstallCoordination.framework/InstallCoordination", RTLD_NOW)
        var refusals: [String] = []
        if let coordinatorClass = NSClassFromString("IXAppInstallCoordinator"),
           class_getClassMethod(coordinatorClass, NSSelectorFromString("uninstallAppWithBundleID:error:")) != nil {
            var error: NSError?
            if unsafeBitCast(coordinatorClass as AnyObject, to: IXInstallCoordinator.self)
                .uninstallAppWithBundleID(bundleID, error: &error) { return nil }
            refusals.append(error.map { "IX \($0.domain) \($0.code): \(describe($0))" } ?? "IX refused without an error")
        }
        if let workspace = workspace() {
            if unsafeBitCast(workspace, to: LSInstallWorkspace.self).uninstallApplication(bundleID, withOptions: nil) { return nil }
            refusals.append("LS refused")
        }
        return refusals.isEmpty ? "no uninstall API available" : refusals.joined(separator: "; ")
    }

    /// installd keeps a refused install's coordinator pending for a moment, and
    /// an uninstall inside that window is refused. Retry briefly until the
    /// bundle is neither registered nor on disk — that window is device timing,
    /// not a fault in either side, and the last refusal is kept for the report.
    /// ponytail: fixed 20×0.5 s budget; make it adaptive if a slow device needs more.
    private static func removeUntilGone(bundleID: String, appName: String) async -> (gone: Bool, lastRefusal: String?) {
        var lastRefusal: String?
        for _ in 0..<20 {
            lastRefusal = await uninstall(bundleID: bundleID)
            if isRegistered(bundleID: bundleID) == false, bundleOnDisk(named: appName) == false { return (true, lastRefusal) }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return (false, lastRefusal)
    }

    /// Nil means the lookup could not establish whether a registration exists.
    private static func isRegistered(bundleID: String) -> Bool? {
        guard let proxyClass = NSClassFromString("LSApplicationProxy") as? NSObject.Type,
              proxyClass.responds(to: NSSelectorFromString("applicationProxyForIdentifier:")) else { return nil }
        guard let proxy = proxyClass.perform(NSSelectorFromString("applicationProxyForIdentifier:"),
                                             with: bundleID)?.takeUnretainedValue() as? NSObject else { return false }
        guard proxy.responds(to: NSSelectorFromString("bundleURL")) else { return nil }
        guard let value = proxy.perform(NSSelectorFromString("bundleURL"))?.takeUnretainedValue() else { return false }
        return value is URL ? true : nil
    }

    /// Whether any install API is usable by *this* process. iOS 15 installs
    /// through `LSApplicationWorkspace` and needs no private entitlement; iOS 16+
    /// needs `com.apple.private.InstallCoordination.allowed` to reach
    /// installcoordinationd — the deb and tipa carry it, the sideloaded ipa
    /// cannot, so the self-test skips there rather than failing.
    private static func installSupported() -> Bool {
        if #available(iOS 16, *) { return coordinationReachable() }
        return NSClassFromString("LSApplicationWorkspace") != nil
    }

    /// A cheap XPC round-trip to installcoordinationd — a bundle lookup, no
    /// package — to learn whether this process may talk to it at all. A refusal
    /// here is the same missing-entitlement wall a real install hits, without
    /// building a fixture first. `SecTask` entitlement reading is private on
    /// iOS, so this is the portable way to ask.
    private static func coordinationReachable() -> Bool {
        _ = dlopen("/System/Library/PrivateFrameworks/InstallCoordination.framework/InstallCoordination", RTLD_NOW)
        guard let coordinatorClass = NSClassFromString("IXAppInstallCoordinator"),
              class_getClassMethod(coordinatorClass, NSSelectorFromString("existingCoordinatorForAppWithBundleID:error:")) != nil
        else { return false }
        var error: NSError?
        _ = unsafeBitCast(coordinatorClass as AnyObject, to: IXInstallCoordinator.self)
            .existingCoordinatorForAppWithBundleID("wiki.qaq.fila.selftest.probe", error: &error)
        guard let error else { return true }
        return !isConnectionRefusal(error)
    }

    /// The self-test's install check. It verifies the installer connection and
    /// a fresh fixture identity, then builds and installs its own copy in the
    /// app workspace. It never replaces a preexisting application or returns
    /// a PASS it did not earn: an unprivileged backend or
    /// an unreachable installer → skip; installd refusing the fixture's
    /// signature → skip, after its placeholder is removed and verified gone;
    /// any other error, or a leftover bundle → failure.
    @MainActor
    static func selfTestCheck() async -> (passes: [String], skipped: String?, failure: String?) {
        let session = FileSession.shared
        let identifier = UUID().uuidString.lowercased()
        let bundleID = "wiki.qaq.fila.selftest." + identifier
        let appName = "FilaSelfTest-" + identifier + ".app"
        var passes: [String] = []

        guard let hello = await session.ready(within: 5), hello.isPrivileged else {
            return (passes, "app install/uninstall — needs the root daemon", nil)
        }
        guard installSupported() else {
            return (passes, "app install/uninstall — installcoordinationd refused this process (needs com.apple.private.InstallCoordination.allowed)", nil)
        }
        passes.append("installcoordinationd accepts this process")

        // This run owns only its fresh identity. Never uninstall an existing
        // app merely because it has a name used by an earlier self-test.
        guard isRegistered(bundleID: bundleID) == false, bundleOnDisk(named: appName) == false else {
            return (passes, nil, "the new fixture identity could not be verified absent")
        }
        passes.append("the unique fixture identity is absent before installation")

        // Fixture, then the install, then whatever cleanup the outcome needs.
        // The workspace is made here so that every exit below — a fixture that
        // failed to build included — deletes it at the end, and a delete that
        // did not succeed fails this check rather than passing with leftovers.
        let workspace: URL
        do { workspace = try await session.makeTemporaryDirectory() }
        catch { return (passes, nil, "app install fixture workspace could not be created: \(error)") }
        var skipped: String?
        var failure: String?
        var outcome: Outcome?
        do {
            let ipa = try await buildFixture(in: workspace, bundleID: bundleID, appName: appName, session: session)
            outcome = await install(ipaAt: URL(fileURLWithPath: ipa), packageType: "Developer")
        } catch { failure = "app install fixture build failed: \(error)" }
        switch outcome {
        case nil:
            break
        case let .unsupported(reason)?:
            skipped = "app install — \(reason)"
        case .failed? where outcome?.isSignatureRefusal == true:
            // installd registers a placeholder before it verifies, so the
            // refused install must still be uninstalled — and that is a real
            // exercise of the uninstall half.
            let hadPlaceholder = isRegistered(bundleID: bundleID) == true || bundleOnDisk(named: appName) == true
            let removal = await removeUntilGone(bundleID: bundleID, appName: appName)
            if !removal.gone {
                failure = "installd left a \(bundleID) placeholder that could not be removed: \(removal.lastRefusal ?? "no error")"
            } else {
                if hadPlaceholder { passes.append("placeholder from the refused install removed") }
                skipped = "app install — this fixture's signature was refused; successful installation remains unverified (\(outcome?.describe ?? ""))"
            }
        case let .failed(domain, code, message)?:
            let removal = await removeUntilGone(bundleID: bundleID, appName: appName)
            let reason = "app install failed: \(domain) \(code) \(message)"
            failure = removal.gone ? reason : "\(reason); fixture removal was not confirmed: \(removal.lastRefusal ?? "no error")"
        case .timedOut?:
            // No cancellation API exists here. Preserve the input while the
            // system may still be consuming it, and never race an uninstall.
            return (passes, nil, "app install outcome unknown; fixture retained at \(workspace.path)")
        case .installed?:
            let registered = isRegistered(bundleID: bundleID)
            let removal = await removeUntilGone(bundleID: bundleID, appName: appName)
            if registered != true { failure = "app install reported success but \(bundleID) is not registered" }
            else if !removal.gone { failure = "app uninstall left \(bundleID) behind: \(removal.lastRefusal ?? "no error")" }
        }

        let cleanup = try? await session.operations.awaitJob(
            JobRequest(kind: .delete, sources: [workspace.path]),
            kind: .delete, subtitle: "self-test fixture", feedback: .silent
        )
        if cleanup?.code != .success {
            failure = failure ?? "self-test fixture at \(workspace.path) was not removed: \(cleanup.map { String(describing: $0) } ?? "delete job failed")"
        }
        return (passes, skipped, failure)
    }

    // MARK: - Fixture

    /// Copies this app's distributable contents into a fresh bundle, re-identifies it
    /// as `bundleID`, and zips it into an `.ipa`. Re-identifying invalidates the
    /// signature — which is intended: the check exercises the path an untrusted
    /// package takes, and AppSync (where present) is what lets it through.
    @MainActor
    private static func buildFixture(in root: URL, bundleID: String, appName: String, session: FileSession) async throws -> String {
        let payload = root.appendingPathComponent("Payload", isDirectory: true)
        try await session.link.create(.directory, at: payload.path)

        let appBundle = payload.appendingPathComponent(appName, isDirectory: true)
        try await session.link.create(.directory, at: appBundle.path)
        let request = try await AppInstallFixture.copyRequest(from: Bundle.main.bundleURL, to: appBundle, link: session.link)
        let copy = try await session.operations.awaitJob(
            request,
            kind: .copy, subtitle: "self-test fixture", feedback: .silent
        )
        guard copy.code == .success else { throw copy }
        try await reidentify(infoPlistAt: appBundle.appendingPathComponent("Info.plist"), bundleID: bundleID, session: session)

        let ipa = root.appendingPathComponent("FilaSelfTest.ipa")
        let archive = try await session.operations.awaitJob(
            JobRequest(kind: .compress, sources: [payload.path], destination: ipa.path, archive: ArchiveOptions()),
            kind: .compress, subtitle: "self-test fixture", feedback: .silent
        )
        guard archive.code == .success else { throw archive }
        return ipa.path
    }

    /// Rewrites CFBundleIdentifier (and the display names) in a bundle's
    /// Info.plist, atomically, through descriptors the daemon opened as root.
    @MainActor
    private static func reidentify(infoPlistAt url: URL, bundleID: String, session: FileSession) async throws {
        let data = try await session.read(url.path)
        guard var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw FilaFailure(code: .operationFailed, systemError: EINVAL, path: url.path)
        }
        plist["CFBundleIdentifier"] = bundleID
        plist["CFBundleName"] = "FilaSelfTest"
        plist["CFBundleDisplayName"] = "Fila Self-Test"
        let rewritten = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try await AtomicSave.write(rewritten, to: url.path, link: session.link)
    }

    /// Whether an app bundle directory of that name sits in the system's app
    /// container root — where installd leaves the placeholder of a refused
    /// install, which LaunchServices may or may not still list.
    private static func bundleOnDisk(named name: String) -> Bool? {
        let root = "/var/containers/Bundle/Application"
        guard let containers = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        for container in containers {
            var metadata = stat()
            if lstat("\(root)/\(container)/\(name)", &metadata) == 0 { return true }
            if errno != ENOENT && errno != ENOTDIR { return nil }
        }
        return false
    }

    // MARK: - Backends

    private static func workspace() -> AnyObject? {
        guard let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return nil }
        return cls.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue()
    }

    private static func installViaWorkspace(_ ipa: URL, packageType: String?) async -> Outcome {
        guard let workspace = workspace() else { return .unsupported("LSApplicationWorkspace unavailable") }
        var options: [String: Any] = [:]
        if let packageType, !packageType.isEmpty { options["PackageType"] = packageType }
        let result: (ok: Bool, error: NSError?) = await Task.detached {
            var error: NSError?
            let ok = unsafeBitCast(workspace, to: LSInstallWorkspace.self).installApplication(ipa, withOptions: options, error: &error)
            return (ok, error)
        }.value
        if result.ok { return .installed }
        guard let error = result.error else { return .failed(domain: "?", code: 0, message: "no error") }
        // The iOS 16+ stub: not a real failure, a "use the other API" signal.
        if error.domain == "NSOSStatusErrorDomain", error.code == -4 {
            return .unsupported("LSApplicationWorkspace install is stubbed on this OS (\(error.code))")
        }
        return .failed(domain: error.domain, code: error.code, message: describe(error))
    }

    private static func installViaCoordination(_ ipa: URL, packageType: String?) async -> Outcome {
        _ = dlopen("/System/Library/PrivateFrameworks/InstallCoordination.framework/InstallCoordination", RTLD_NOW)
        _ = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_NOW)
        guard let coordinatorClass = NSClassFromString("IXAppInstallCoordinator") else {
            return .unsupported("IXAppInstallCoordinator unavailable")
        }
        // A class without the selector raises, and an ObjC exception cannot be
        // caught here: the workspace path (iOS 15) is what runs instead.
        guard class_getClassMethod(coordinatorClass, NSSelectorFromString("installApplication:consumeSource:options:completion:")) != nil else {
            return .unsupported("IXAppInstallCoordinator has no installApplication:consumeSource:options:completion:")
        }
        var options: AnyObject?
        if let packageType, !packageType.isEmpty,
           let optionsClass = NSClassFromString("MIInstallOptions") as? NSObject.Type,
           let instance = optionsClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject {
            options = instance.perform(NSSelectorFromString("initWithLegacyOptionsDictionary:"),
                                       with: ["PackageType": packageType])?.takeUnretainedValue()
        }
        let capturedOptions = options
        return await withCheckedContinuation { continuation in
            // installd's completion and the watchdog below arrive on different
            // queues; the lock lets exactly one of them resume. The timeout
            // owns no callback back to itself and has no cross-queue mutation.
            let lock = NSLock()
            var resumed = false
            let finish: (Outcome) -> Void = { outcome in
                lock.lock()
                let first = !resumed
                resumed = true
                lock.unlock()
                guard first else { return }
                continuation.resume(returning: outcome)
            }
            unsafeBitCast(coordinatorClass as AnyObject, to: IXInstallCoordinator.self)
                .installApplication(ipa, consumeSource: true, options: capturedOptions) { first, second in
                    let error = (first as? NSError) ?? (second as? NSError)
                    guard let error else { finish(.installed); return }
                    if isConnectionRefusal(error) {
                        finish(.unsupported("installcoordinationd refused the connection — needs com.apple.private.InstallCoordination.allowed"))
                    } else {
                        finish(.failed(domain: error.domain, code: error.code, message: describe(error)))
                    }
                }
            // installd can leave the completion unfired if the connection
            // drops; bound the wait so a caller always gets an answer.
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                finish(.timedOut)
            }
        }
    }

    /// A refused XPC connection to installcoordinationd — the missing
    /// `InstallCoordination.allowed` wall. It arrives either directly
    /// (`NSCocoaError 4097`) or wrapped as `IXErrorDomain 1 "Failed to create
    /// temporary staging directory"` with the 4097 in `NSUnderlyingError`.
    private static func isConnectionRefusal(_ error: NSError) -> Bool {
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        return (error.domain == NSCocoaErrorDomain && error.code == 4097)
            || (underlying?.domain == NSCocoaErrorDomain && underlying?.code == 4097)
            || describe(error).contains("installcoordinationd")
    }

    /// The most specific text an error carries: installd puts the real reason
    /// (`0xe800801c …`) in the recovery suggestion, not the description.
    private static func describe(_ error: NSError) -> String {
        if let suggestion = error.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String { return suggestion }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return underlying.localizedDescription }
        return error.localizedDescription
    }
}
