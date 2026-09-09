import AlertController
import FilaBackendKit
import FilaProtocol
import FilaTerminal
import UIKit

extension FileActions {
    /// One Install… entry, routed by format, each behind a card that says what
    /// is about to happen. A `.deb` runs the bootstrap's `dpkg -i` on a
    /// terminal as root, so it needs the daemon and the Run setting like the
    /// Run menu does. A `.tipa` is TrollStore's format and goes to TrollStore
    /// through the share sheet: installd refuses a fake-signed bundle every
    /// time, so there is nothing to try first (Roadmap → IPA installation).
    /// An `.ipa` goes to installd through the applications module, which is
    /// the route AppSync Unified opens; without it the refusal is reported as
    /// such, and a build without the module offers no entry at all.
    func installAction(_ path: String, node: FileNode, confirm: @escaping (@escaping () -> Void) -> Void) -> UIAction? {
        guard node.kind == .regular else { return nil }
        let name = (path as NSString).lastPathComponent
        let install: () -> Void
        switch (path as NSString).pathExtension.lowercased() {
        case "deb":
            guard SystemCapabilities.runsPrograms else { return nil }
            install = { [self] in promptInstallPackage(path) }
        case "tipa":
            install = { [self] in
                confirmDestruction(
                    title: String(localized: "Open in TrollStore?"),
                    message: String(localized: "Choose TrollStore to install “\(name)” without the system installer."),
                    confirm: String(localized: "Open")
                ) { self.share([path]) }
            }
        case "ipa":
            // A sandboxed build has no InstallCoordination entitlement and
            // would copy the whole package only to be refused; the handshake
            // says which build this is, so the entry waits for it.
            guard let backend = session.hello?.backend, backend != .local(reach: .container),
                  let applications = SystemCapabilities.applications else { return nil }
            install = { [self] in promptInstallApp(path, applications: applications) }
        default:
            return nil
        }
        return UIAction(
            title: String(localized: "Install…"),
            image: UIImage(systemName: "arrow.down.app")
        ) { _ in confirm(install) }
    }

    /// Reads the package's identity first, and refuses Fila's own: its postinst
    /// restarts `filad`, and a stopping daemon hangs up every terminal it
    /// spawned — dpkg included, between unpack and configure. That package
    /// goes through the system package manager or the device updater, never a
    /// terminal this daemon owns.
    private func promptInstallPackage(_ path: String) {
        let name = (path as NSString).lastPathComponent
        Task {
            let staged: URL
            do { staged = try await session.stage(path) }
            catch { report(error); return }
            let cleanup: @MainActor @Sendable () -> Void = { [self] in
                do { try FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
                catch { report(error) }
            }
            do {
                let manifest = try await DebianPackage.manifest(ofDebAt: staged.path, session: session)
                guard manifest.package != Bundle.main.bundleIdentifier else {
                    throw ViewerFailure.unsupportedContent(String(localized: "“\(name)” is Fila itself and cannot be installed from here. Install it with your package manager."))
                }
                guard let presenter = activePresenter else { cleanup(); return }
                let alert = AlertViewController(
                    title: String(localized: "Install Package?"),
                    message: String(localized: "Installs “\(name)” as root with dpkg. A faulty package can damage the system environment or leave the device unable to start. This cannot be undone.")
                ) { context in
                    context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose { cleanup() } }
                    context.addAction(title: String.LocalizationValue("Install"), attribute: .accent) {
                        context.dispose {
                            if !self.openTerminal(
                                .installPackage(path: staged.path),
                                user: .root,
                                onProcessExit: cleanup
                            ) {
                                cleanup()
                            }
                        }
                    }
                }
                presenter.present(alert, animated: true)
            } catch { cleanup(); report(error) }
        }
    }

    /// Keep package confirmations and installs serial across all file screens.
    /// Different paths can contain packages for the same application.
    private static var appInstallInFlight = false

    /// Stages the copy first — the installer consumes what it is handed — and
    /// reads the manifest from that copy, so the card, the install and any
    /// cleanup all describe the same bytes even if the original is replaced
    /// while the card is up.
    private func promptInstallApp(_ path: String, applications: any ApplicationCapability) {
        guard !Self.appInstallInFlight else {
            FeedbackAlert.show(
                String(localized: "Installation in Progress"),
                message: String(localized: "Wait for the current installation to finish, then try again.")
            )
            return
        }
        Self.appInstallInFlight = true
        Task {
            let progress = await presentProgress(title: String.LocalizationValue("Reading App…"))
            let staged: URL
            let manifest: PackageManifest
            do {
                staged = try await session.stage(path)
                do { manifest = try await applications.manifest(ofPackageAt: staged) } catch {
                    try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                    throw error
                }
            } catch {
                await dismiss(progress)
                Self.appInstallInFlight = false
                report(error)
                return
            }
            await dismiss(progress)
            guard let presenter = activePresenter else {
                try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                Self.appInstallInFlight = false
                return
            }
            let alert = AlertViewController(
                title: String(localized: "Install App?"),
                message: String(localized: "The system installer will install “\(manifest.displayName)” (\(manifest.bundleIdentifier)), replacing any app with the same identifier. Apps not signed for this device require AppSync Unified.")
            ) { context in
                context.addAction(title: String.LocalizationValue("Cancel")) {
                    context.dispose {
                        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                        Self.appInstallInFlight = false
                    }
                }
                context.addAction(title: String.LocalizationValue("Install"), attribute: .accent) {
                    context.dispose {
                        Task { await self.installApp(path, staged: staged, manifest: manifest, applications: applications) }
                    }
                }
            }
            presenter.present(alert, animated: true)
        }
    }

    /// A failure does not establish ownership of anything now registered under
    /// the identifier. The system or another installer may have changed it, so
    /// uninstall remains an explicit user action in Applications.
    private func installApp(
        _ path: String, staged: URL, manifest: PackageManifest, applications: any ApplicationCapability
    ) async {
        let progress = await presentProgress(title: String.LocalizationValue("Installing App…"))
        let outcome = await applications.install(packageAt: staged)
        // An unanswered request may still be reading its source. Preserve the
        // workspace and keep further requests disabled for this session.
        switch outcome {
        case .timedOut: break
        default:
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            Self.appInstallInFlight = false
        }
        await dismiss(progress)
        switch outcome {
        case .installed:
            Toast.show(String(localized: "App Installed"))
        case .unsupported:
            reportInstallRefusal(
                path,
                message: String(localized: "Fila cannot use the system installer. Open “\(manifest.displayName)” with another installer.")
            )
        case .timedOut:
            report(NSError(
                domain: "ApplicationInstaller",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "The installer is still working. Check Applications before trying again."
                    ),
                ]
            ))
        case let .failed(domain, code, message):
            if outcome.isSignatureRefusal {
                reportInstallRefusal(
                    path,
                    message: String(localized: "The signature of “\(manifest.displayName)” was rejected. Install AppSync Unified on this device or open the file in TrollStore.")
                )
            } else {
                report(NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message]))
            }
        }
    }

    /// Copying and installing a package is never a blink, so the card shows at
    /// once rather than after the delete path's reveal delay.
    private func presentProgress(title: String.LocalizationValue) async -> AlertProgressIndicatorViewController? {
        guard let presenter = activePresenter else { return nil }
        let progress = AlertProgressIndicatorViewController(
            title: title,
            message: String.LocalizationValue("Large packages take time.")
        )
        await withCheckedContinuation { continuation in
            presenter.present(progress, animated: true) { continuation.resume() }
        }
        return progress
    }

    private func dismiss(_ progress: AlertProgressIndicatorViewController?) async {
        guard let progress else { return }
        await withCheckedContinuation { continuation in
            progress.dismiss(animated: true) { continuation.resume() }
        }
    }

    /// A refusal with a way out: the same share sheet the `.tipa` route uses,
    /// where TrollStore (or another installer) is one tap away.
    private func reportInstallRefusal(_ path: String, message: String) {
        guard let presenter = activePresenter else {
            FeedbackAlert.show(String(localized: "Cannot Install"), message: message)
            return
        }
        let alert = AlertViewController(
            title: String(localized: "Cannot Install"),
            message: message
        ) { context in
            context.addAction(title: String.LocalizationValue("Cancel")) {
                context.dispose()
            }
            context.addAction(title: String.LocalizationValue("Open With…"), attribute: .accent) {
                context.dispose { self.share([path]) }
            }
        }
        presenter.present(alert, animated: true)
    }
}
