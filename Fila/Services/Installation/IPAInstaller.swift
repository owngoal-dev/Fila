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
}

/// InstallCoordination's class methods, sent to the class object itself (a
/// class receives its own `+` messages), so the same trick reaches them.
/// `installApplication:` takes a file URL and an `MIInstallOptions`.
@objc private protocol IXInstallCoordinator {
    func installApplication(
        _ url: URL,
        consumeSource: Bool,
        options: AnyObject?,
        completion: @escaping (AnyObject?, AnyObject?) -> Void
    )
}

/// Installs an `.ipa` for the file menu's Install… action using the runtime chain
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
            case .installed: "installed"
            case let .failed(domain, code, message): "FAILED \(domain) \(code): \(message)"
            case let .unsupported(reason): "unsupported: \(reason)"
            case .timedOut: "install outcome unknown: no completion in 60s"
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
            if case .unsupported = viaWorkspace {
                return viaCoordinator
            }
            return viaWorkspace
        }
        return viaCoordinator
    }

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
            let notAnApp = ViewerFailure.unsupportedContent(String(
                localized: "“\(url.lastPathComponent)” is not an app package. Choose an .ipa that contains one app."
            ))
            let reader = try ArchiveReader(descriptor: descriptor)
            var found: Manifest?
            while let entry = try reader.next() {
                let parts = entry.declaredPath.split(separator: "/")
                guard parts.count == 3, parts[0] == "Payload", parts[1].hasSuffix(".app"),
                      parts[2] == "Info.plist" else { continue }
                let data = try reader.data(maximumByteCount: 4 * 1024 * 1024)
                guard found == nil,
                      let plist = try PropertyListSerialization
                      .propertyList(from: data, options: [], format: nil) as? [String: Any],
                      let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty
                else { throw notAnApp }
                let bundleName = String(parts[1])
                let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
                found = Manifest(
                    bundleID: bundleID,
                    displayName: name.flatMap { $0.isEmpty ? nil : $0 }
                        ?? (bundleName as NSString).deletingPathExtension
                )
            }
            guard let found else { throw notAnApp }
            return found
        }.value
    }

    // MARK: - Backends

    private static func workspace() -> AnyObject? {
        guard let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return nil }
        return cls.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue()
    }

    private static func installViaWorkspace(_ ipa: URL, packageType: String?) async -> Outcome {
        guard let workspace = workspace() else { return .unsupported("LSApplicationWorkspace unavailable") }
        var options: [String: Any] = [:]
        if let packageType, !packageType.isEmpty {
            options["PackageType"] = packageType
        }
        let result: (ok: Bool, error: NSError?) = await Task.detached {
            var error: NSError?
            let ok = unsafeBitCast(workspace, to: LSInstallWorkspace.self)
                .installApplication(ipa, withOptions: options, error: &error)
            return (ok, error)
        }.value
        if result.ok {
            return .installed
        }
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
        guard class_getClassMethod(
            coordinatorClass,
            NSSelectorFromString("installApplication:consumeSource:options:completion:")
        ) != nil else {
            return .unsupported("IXAppInstallCoordinator has no installApplication:consumeSource:options:completion:")
        }
        var options: AnyObject?
        if let packageType, !packageType.isEmpty,
           let optionsClass = NSClassFromString("MIInstallOptions") as? NSObject.Type,
           let instance = optionsClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
        {
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
        if let suggestion = error.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String {
            return suggestion
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.localizedDescription
        }
        return error.localizedDescription
    }
}
