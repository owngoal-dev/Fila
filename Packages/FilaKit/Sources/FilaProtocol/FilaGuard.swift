import Foundation

/// The one thing standing between a root file manager and a brick.
///
/// The rule is narrow on purpose: a node on this list may not itself be deleted,
/// moved away, or replaced — but everything *inside* it stays editable, because
/// editing files inside `/System` and `/var/mobile` is the entire point of the
/// app. Refusing whole subtrees would make Fila useless; refusing nothing makes
/// one mistyped gesture unrecoverable.
///
/// This lives in FilaProtocol so the harness can test it on macOS, but only the
/// daemon is allowed to *enforce* it. The client is untrusted UI: it may grey a
/// menu item out as a courtesy, and that is all it may do.
public enum FilaGuard {
    /// Paths that are refused as the target of a destructive operation.
    ///
    /// `bootstrapRoot` is where the jailbreak installed us — randomized on
    /// roothide, `/var/jb` on rootless, empty on a rootful layout — and is
    /// derived from the daemon's own `proc_pidpath`, never hardcoded. Deleting
    /// it takes the jailbreak, and Fila, with it.
    public static func protectedRoots(bootstrapRoot: String) -> [String] {
        var roots = [
            "/",
            "/Applications",
            "/Library",
            "/System",
            "/bin",
            "/cores",
            "/dev",
            "/opt",
            "/private",
            "/private/etc",
            "/private/preboot",
            "/private/tmp",
            "/private/var",
            "/private/var/containers",
            "/private/var/db",
            "/private/var/mobile",
            "/private/var/mobile/Containers",
            "/private/var/mobile/Library",
            "/private/var/root",
            "/sbin",
            "/usr",
            // Host-harness paths: tests run on macOS and must not delete the Mac.
            "/Network",
            "/System/Volumes",
            "/Users",
            "/Volumes",
        ]
        let root = normalize(bootstrapRoot)
        if root != "/" {
            roots.append(root)
            // The bootstrap's own top-level directories are as fatal as the
            // rootful ones they shadow.
            roots.append(contentsOf: ["/Applications", "/Library", "/usr", "/var", "/etc"].map { root + $0 })
        }
        return roots
    }

    /// Whether `path` may not be deleted, moved away, or overwritten.
    ///
    /// Pass a path that has already been through `realpath(3)`: `/var` and
    /// `/etc` are symlinks into `/private` on every Apple platform, and a
    /// listing that walked in through one of them would otherwise slip past a
    /// literal comparison. The lexical `normalize` below is defence in depth,
    /// not a substitute.
    public static func isDestructionProtected(_ path: String, bootstrapRoot: String) -> Bool {
        let target = normalize(path)
        return protectedRoots(bootstrapRoot: bootstrapRoot).contains { root in
            let root = normalize(root)
            // Equal — deleting the node itself.
            // Ancestor — deleting `/private` takes `/private/var` with it.
            return target == root || isAncestor(target, of: root)
        }
    }

    /// True when `ancestor` contains `path`. `/private` contains
    /// `/private/var`; `/priv` does not.
    public static func isAncestor(_ ancestor: String, of path: String) -> Bool {
        let ancestor = normalize(ancestor)
        let path = normalize(path)
        if ancestor == "/" {
            return path != "/"
        }
        return path.hasPrefix(ancestor + "/")
    }

    /// Lexical cleanup: absolute, no repeated or trailing slashes, `.` dropped,
    /// `..` resolved against what came before. Never touches the filesystem.
    public static func normalize(_ path: String) -> String {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(String(component))
            }
        }
        return "/" + components.joined(separator: "/")
    }
}
