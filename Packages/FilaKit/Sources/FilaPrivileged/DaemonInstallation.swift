import Darwin
import Foundation

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
