import Darwin
import FilaProtocol
import Foundation

/// Turning the string a client sent into the string every decision is made
/// about.
///
/// `/var` and `/etc` are symlinks into `/private` on every Apple platform, so a
/// guard that compares what arrived on the wire is a guard with a bypass. This
/// is where that stops being possible, and everything in `FilaFileOps` starts
/// here.
public enum FilaPath {
    /// `realpath(3)` on the parent, with the last component appended unresolved.
    ///
    /// Resolving the whole path would be wrong twice over. It fails for a node
    /// that does not exist yet — every create, and the destination of every
    /// rename — and where the last component is itself a symlink it names the
    /// target instead of the link, so a delete would take the wrong file. The
    /// parent is what carries `/var` → `/private/var`, and resolving the parent
    /// is all the guard needs: `/var/mobile/../mobile` resolves through the
    /// kernel, not through a lexical rule that a symlinked component would
    /// break.
    public static func canonical(_ path: String) throws -> String {
        // A relative path in a root daemon is a client bug, and the daemon's
        // working directory is not something either side should be reasoning
        // about. Embedded NUL would make C syscalls use a different name from
        // the complete Swift string that the guard checked.
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL, path: path)
        }

        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard trimmed != "/" else { return "/" }

        let separator = trimmed.lastIndex(of: "/")!
        let leaf = String(trimmed[trimmed.index(after: separator)...])
        // `.` and `..` do not name a node, so there is nothing to hold back
        // from `realpath`.
        guard leaf != ".", leaf != ".." else { return try resolve(trimmed) }

        let parent = separator == trimmed.startIndex ? "/" : String(trimmed[..<separator])
        return try join(resolve(parent), leaf)
    }

    /// `realpath(3)`. Everything it is given must exist.
    public static func resolve(_ path: String) throws -> String {
        guard !path.utf8.contains(0) else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL, path: path)
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let resolved = path.withCString { source in
            buffer.withUnsafeMutableBufferPointer { realpath(source, $0.baseAddress) }
        }
        guard resolved != nil else { throw FilaFailure(errno: Darwin.errno, path: path) }
        return String(cString: buffer)
    }

    /// The directory an already-canonical path sits in. `/` is its own parent.
    public static func directory(of path: String) -> String {
        guard let separator = path.lastIndex(of: "/"), separator != path.startIndex else { return "/" }
        return String(path[..<separator])
    }

    /// The last component of an already-canonical path. The volume root is its
    /// own name, because the alternative is an empty string in the one place a
    /// browser has to print something.
    public static func name(of path: String) -> String {
        guard path != "/", let separator = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: separator)...])
    }

    /// A child of `directory`, without the doubled separator that `"/" + name`
    /// produces at the volume root.
    public static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }
}

/// Whether anything at all is at `path` — a dangling symlink counts, because it
/// is still something a rename would clobber.
public func filaExists(_ path: String) -> Bool {
    var metadata = stat()
    return lstat(path, &metadata) == 0
}
