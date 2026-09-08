import Darwin
import Foundation

/// One line of the bootstrap's own `/etc/passwd`.
///
/// Read from the bootstrap's root rather than through `getpwuid`, because libc
/// answers from the *system's* database: on a jailbroken device root's shell
/// there is `/bin/sh` (which does not exist) and its home is `/var/root`, while
/// the bootstrap's entry names the zsh the user actually installed, already in
/// the spelling its own programs use.
struct PasswdEntry {
    var name: String
    var uid: uid_t
    var gid: gid_t
    var home: String
    var shell: String

    /// The entry for whoever this process is — root on the device.
    static func current(layout: BootstrapLayout) -> PasswdEntry? {
        let uid = getuid()
        return bootstrapEntry(layout: layout) { $0.uid == uid } ?? systemEntry(getpwuid(uid))
    }

    /// The entry for a named account. Only ever called with
    /// `TerminalUser.mobileName`: a name is the whole of what a caller can ask
    /// for, and it is not the caller who supplies even that.
    static func named(_ name: String, layout: BootstrapLayout) -> PasswdEntry? {
        bootstrapEntry(layout: layout) { $0.name == name } ?? systemEntry(getpwnam(name))
    }

    private static func bootstrapEntry(
        layout: BootstrapLayout,
        matching: (PasswdEntry) -> Bool
    ) -> PasswdEntry? {
        let path = layout.resolve(layout.bootstrapPath("/etc/passwd"))
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 7, let uid = uid_t(fields[2]), let gid = gid_t(fields[3]) else { continue }
            let entry = PasswdEntry(
                name: String(fields[0]),
                uid: uid,
                gid: gid,
                home: String(fields[5]),
                shell: String(fields[6])
            )
            if matching(entry) { return entry }
        }
        return nil
    }

    private static func systemEntry(_ entry: UnsafeMutablePointer<passwd>?) -> PasswdEntry? {
        guard let entry else { return nil }
        return PasswdEntry(
            name: String(cString: entry.pointee.pw_name),
            uid: entry.pointee.pw_uid,
            gid: entry.pointee.pw_gid,
            home: String(cString: entry.pointee.pw_dir),
            shell: String(cString: entry.pointee.pw_shell)
        )
    }
}
