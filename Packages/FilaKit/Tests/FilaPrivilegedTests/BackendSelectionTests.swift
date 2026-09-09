import CRemoveFile
import Darwin
import FilaClient
@testable import FilaPrivileged
@testable import FilaProtocol
import Foundation
import Testing

/// The rule that decides whether the app runs as root or as itself.
///
/// It is worth a test target of its own because getting it wrong is silent in
/// both directions: too eager and a jailbroken device quietly loses root
/// halfway through a respring, too reluctant and the `.tipa` and the `.ipa` sit
/// on *Connecting…* forever, which is the bug this exists to fix.
@Suite("Backend selection")
struct BackendSelectionTests {
    /// A `<prefix>/Applications/Fila.app` layout, optionally with the daemon
    /// installed beside it — the deb's shape, in a temporary directory.
    private func layout(withDaemon: Bool) -> URL {
        let prefix = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fila-install-\(UInt32.random(in: 0 ..< .max))", isDirectory: true)
        let bundle = prefix.appendingPathComponent("Applications/Fila.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        if withDaemon {
            let libexec = prefix.appendingPathComponent("usr/libexec", isDirectory: true)
            try? FileManager.default.createDirectory(at: libexec, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: libexec.appendingPathComponent("filad").path, contents: Data())
        }
        return bundle
    }

    @Test("A deb layout with the daemon beside the app is a daemon install")
    func findsTheInstalledDaemon() {
        #expect(DaemonInstallation.isInstalled(besideBundleAt: layout(withDaemon: true)))
    }

    @Test("The same layout without the binary is not")
    func daemonMustActuallyBeThere() {
        #expect(!DaemonInstallation.isInstalled(besideBundleAt: layout(withDaemon: false)))
    }

    /// TrollStore and every sideloading tool land here, and the simulator in
    /// the runtime's equivalent. The check has to answer false without touching
    /// the filesystem — a sandboxed app asking about a path outside its
    /// container is a sandbox violation for no gain.
    @Test("An app installed outside an `Applications` directory never is")
    func containerInstallIsNotADaemonInstall() {
        let bundle = URL(fileURLWithPath: "/private/var/containers/Bundle/Application/UUID/Fila.app")
        #expect(!DaemonInstallation.isInstalled(besideBundleAt: bundle))
    }

    @Test("A rootful layout resolves against the volume root")
    func rootfulLayout() {
        // `/Applications/Fila.app` means `<empty prefix>/usr/libexec/filad`.
        // Nothing is installed there in a test run, so the answer is false —
        // what is under test is that it looks at `/usr/libexec/filad` rather
        // than falling over the empty prefix.
        #expect(!DaemonInstallation.isInstalled(besideBundleAt: URL(fileURLWithPath: "/Applications/Fila.app")))
    }

    /// The half of the rule that keeps a jailbroken device from being demoted:
    /// with a daemon installed, a lookup that fails throws and `FileSession`
    /// goes on retrying. There is no path from here to the local backend.
    @Test("A missing daemon that is installed keeps throwing rather than falling back")
    func neverDemotesAnInstalledDaemon() async {
        let link = DaemonLink(daemonIsInstalled: true)
        // However many times it is asked. There is no count that releases an
        // installed daemon, which is the difference between this and a timeout.
        for _ in 0 ..< 8 {
            await #expect(throws: (any Error).self) { try await link.hello() }
        }
    }

    /// The other half: with no daemon installed, the app stops waiting for
    /// something nobody shipped — but not on the first miss, so a TrollStore
    /// install on a jailbroken device is not demoted by one badly timed lookup.
    /// The grace period is a duration and not a count of attempts, and this is
    /// the property that distinguishes them: asking faster must not shorten it.
    /// A count meant three seconds to `ready()`, which asks once a second, and
    /// three quarters of a second to `ready(within:)`, which asks four times —
    /// so a Shortcut run at launch could settle for the unprivileged backend
    /// before launchd had finished starting the daemon.
    @Test("Asking faster does not shorten the grace period")
    func pollingRateDoesNotDemote() async {
        let link = DaemonLink(daemonIsInstalled: false, grace: 60)
        for _ in 0 ..< 50 {
            await #expect(throws: (any Error).self) { try await link.hello() }
        }
    }

    @Test("No daemon installed falls back in-process once the grace period is up, for good")
    func fallsBackWhenNothingIsInstalled() async throws {
        // Zero grace so the first miss starts the clock and the second is past
        // it. The rule under test is "the clock, not the count"; how long the
        // clock runs for in production is a constant, not a behaviour.
        let link = DaemonLink(daemonIsInstalled: false, grace: 0)
        await #expect(throws: (any Error).self) { try await link.hello() }
        let hello = try await link.hello()
        #expect(hello.protocolVersion == FilaProtocol.version)
        #expect(!hello.isPrivileged)
        #expect(hello.installRoot.isEmpty)
        guard case .local = hello.backend else {
            Issue.record("expected the local backend, got \(hello.backend)")
            return
        }
        // The choice is made once: a second handshake must not re-run the
        // lookup and must not answer differently.
        let again = try await link.hello()
        #expect(again.backend == hello.backend)
    }

    /// Once the link has fallen back, the requests it forwards and the
    /// events it reports are the in-process service's — on the streams the
    /// app was already reading before the handshake chose.
    @Test("A fallen-back link lists and reports jobs through the streams it owned all along")
    func fallbackWiring() async throws {
        let link = DaemonLink(daemonIsInstalled: false, grace: 0)
        _ = try? await link.hello()
        _ = try await link.hello()

        let root = NSTemporaryDirectory() + "fila-fallback-\(UInt32.random(in: 0 ..< .max))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { removefile(root, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) }
        try await link.create(.emptyFile, at: root + "/one")
        let page = try await link.list(directory: root)
        #expect(page.entries.map(\.name) == ["one"])

        let identifier = try await link.startJob(JobRequest(kind: .delete, sources: [root + "/one"], useTrash: false))
        var completed = false
        for await update in link.jobEvents where update.identifier == identifier {
            if case .completed = update.event {
                completed = true
                break
            }
        }
        #expect(completed)
        #expect(access(root + "/one", F_OK) != 0)
    }
}
