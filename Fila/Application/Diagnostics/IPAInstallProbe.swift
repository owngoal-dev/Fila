#if DEBUG
import FilaLog
import UIKit

/// Debug-only probe that installs an `.ipa` from **this** process (mobile, with
/// the deb's entitlements), through the shared `IPAInstaller`. The Method field
/// forces one backend for testing — `LS` for `LSApplicationWorkspace`, `IX` for
/// `IXAppInstallCoordinator` — while `IPAInstaller.install` (used by the
/// self-test) picks the right one per OS. It copies the package first because
/// the installer consumes what it is handed, and reports the exact `NSError` so
/// a failure names its blocker.
///
/// Deliberately in the app and not in `filad`: `installd` does the work as
/// `_installd` whichever process asks, so root buys nothing, and a daemon
/// operation "install this path" would be a new named primitive for no gain.
@MainActor
enum IPAInstallProbe {
    static func present(from controller: UIViewController) {
        let alert = UIAlertController(
            title: "Install IPA Probe",
            message: "Copies the package, then installs it via LSApplicationWorkspace (LS) or InstallCoordination (IX).",
            preferredStyle: .alert
        )
        alert.addTextField { $0.text = "/var/mobile/Downloads/FilaProbe.ipa"; $0.placeholder = "Path to .ipa" }
        alert.addTextField { $0.text = "Developer"; $0.placeholder = "PackageType (empty: none)" }
        alert.addTextField { $0.text = "IX"; $0.placeholder = "Method: LS or IX" }
        alert.addTextField { $0.text = ""; $0.placeholder = "Staging directory (empty: app workspace)" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Install", style: .destructive) { [weak controller] _ in
            let fields = alert.textFields ?? []
            let path = fields[0].text ?? ""
            let packageType = fields[1].text ?? ""
            let method = (fields[2].text ?? "IX").uppercased()
            let staging = fields[3].text ?? ""
            Task {
                let report = await run(path: path, packageType: packageType, method: method, staging: staging)
                FilaLog.info("IPA install probe\n\(report)")
                let result = UIAlertController(title: "IPA Probe Result", message: report, preferredStyle: .alert)
                result.addAction(UIAlertAction(title: "OK", style: .default))
                controller?.present(result, animated: true)
            }
        })
        controller.present(alert, animated: true)
    }

    private static func run(path: String, packageType: String, method: String, staging: String) async -> String {
        var report = "uid \(getuid()) method \(method)\n"
        var copy: URL?
        var retainInput = false
        defer { if !retainInput { copy.map { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } } }
        do {
            if staging.isEmpty {
                copy = try await FileSession.shared.stage(path)
            } else {
                let directory = URL(fileURLWithPath: staging).appendingPathComponent("fila-probe-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                let target = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
                copy = target
            }
            guard let copy else { return report + "no copy" }
            report += "copy \(copy.path)\npackageType \(packageType.isEmpty ? "(none)" : packageType)\n"
            let type = packageType.isEmpty ? nil : packageType
            let outcome = method == "LS"
                ? await IPAInstaller.installForcingWorkspace(copy, packageType: type)
                : await IPAInstaller.install(ipaAt: copy, packageType: type)
            report += outcome.describe
            if case .timedOut = outcome { retainInput = true }
            report += "\ncopy still present: \(FileManager.default.fileExists(atPath: copy.path) ? "yes" : "no (consumed)")"
        } catch {
            report += "failed before install: \(error)"
        }
        return report
    }
}
#endif
