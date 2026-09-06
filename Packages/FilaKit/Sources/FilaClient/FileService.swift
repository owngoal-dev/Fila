import Darwin
import FilaLog
import FilaProtocol
import Foundation

/// Everything the app can ask for, and the two places an answer can come from.
///
/// `DaemonFileService` sends the request to `filad` over XPC, where it runs as
/// root. `LocalFileService` does the same work in this process, as whoever the
/// app is running as. They are the same operations because underneath they are
/// the same code: the daemon is a dispatcher over `FilaFileOps`, and so is the
/// local service. Nothing in the file layer — not a `copyfile` call, not the
/// guard, not a path canonicalisation — is written twice.
///
/// The signatures are `DaemonLink`'s, unchanged, because the app has hundreds
/// of call sites shaped `session.perform { try await $0.list(…) }` and the
/// abstraction is not worth one edit to any of them.
protocol FileService: AnyObject, Sendable {
    func hello() async throws -> DaemonLink.Hello
    func list(directory: String, cursor: UInt64) async throws -> DaemonLink.DirectoryPage
    func details(of path: String) async throws -> FileDetails
    func open(_ path: String, flags: Int32, mode: mode_t) async throws -> Int32
    func create(_ template: NodeTemplate, at path: String) async throws
    func rename(_ source: String, to destination: String, exclusive: Bool, overrideGuard: Bool) async throws
    func setAttributes(_ change: AttributeChange, at path: String) async throws
    func replaceItem(at target: String, withTemporary temporary: String) async throws
    func mountPoints() async throws -> [MountPoint]
    func volumeInfo(for path: String) async throws -> VolumeInfo
    func extendedAttribute(_ name: String, at path: String) async throws -> Data
    func startJob(_ job: JobRequest) async throws -> UInt64
    func cancelJob(_ identifier: UInt64) async throws
    /// The *other* process's log. Empty when there is no other process.
    func fetchLog(since sequence: UInt64, level: FilaLog.Level) async throws
        -> (records: [FilaLog.Record], dropped: UInt64)
}

/// Whether this copy of the app was installed with `filad` beside it.
///
/// This is the fact the backend choice turns on, and it is on disk rather than
/// in a build flag on purpose: one binary ships in four wrappers and only one
/// of them — the `.deb` — carries the daemon.
enum DaemonInstallation {
    /// The daemon's binary, found from the app's own bundle path and nothing
    /// else.
    ///
    /// `make deb` installs the app at `<prefix>/Applications/Fila.app` and the
    /// daemon at `<prefix>/usr/libexec/filad`, for every bootstrap: `<prefix>`
    /// is empty on a rootful layout, `/var/jb` on rootless and a randomized
    /// directory on roothide. Deriving it from where we are, the way
    /// `InstallRoot` derives it from the daemon's own `proc_pidpath`, is what
    /// keeps the prefix out of Swift.
    ///
    /// Nothing else installs the app into a directory named `Applications`: a
    /// TrollStore `.tipa` and a sideloaded `.ipa` both land in
    /// `…/Bundle/Application/<UUID>/Fila.app`, and the simulator in the
    /// runtime's own container. Those answer false on the first line, without
    /// touching the filesystem at all — which also means a sandboxed build
    /// never trips a sandbox denial asking this question.
    ///
    /// Only "it is not there" answers false. `access(2)` fails for reasons that
    /// are not absence — `EACCES` from an ancestor we may not search, `ELOOP`,
    /// `ENAMETOOLONG` — and "I could not look" must not be read as "no daemon
    /// installed": that is the answer that demotes the app, and it would demote
    /// a device that has a daemon. Not knowing means assuming the daemon is
    /// there and waiting for it, which is what this app does anyway.
    static func isInstalled(besideBundleAt bundle: URL) -> Bool {
        let applications = bundle.deletingLastPathComponent()
        guard applications.lastPathComponent == "Applications" else { return false }
        let daemon = applications
            .deletingLastPathComponent()
            .appendingPathComponent("usr/libexec/filad")
        guard access(daemon.path, F_OK) != 0 else { return true }
        return errno != ENOENT && errno != ENOTDIR
    }
}
