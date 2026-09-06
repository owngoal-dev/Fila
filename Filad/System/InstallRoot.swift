import Darwin
import FilaLog
import Foundation

/// Where the jailbreak put us.
///
/// roothide relocates rootful paths into a randomized bootstrap directory and
/// rootless installs under a fixed `/var/jb`, so the prefix is never known at
/// build time and must never be written into Swift. The daemon reads its own
/// executable path instead: everything hung off the install prefix — the app it
/// will admit as a client, the file operation write boundary — starts
/// here.
enum InstallRoot {
    /// The prefix the package was installed under. Empty on a rootful layout
    /// only; a resolved bootstrap directory on rootless and roothide.
    static let current: String = {
        let suffix = "/usr/libexec/filad"
        guard let path = filaProcessPath(pid: getpid()), path.hasSuffix(suffix) else {
            // An unknown layout must not become an unrestricted rootful
            // backend. This is evaluated before the listener is registered.
            FilaLog.error("filad could not determine its install root")
            exit(EXIT_FAILURE)
        }
        return String(path.dropLast(suffix.count))
    }()
}
