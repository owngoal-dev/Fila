import CRemoveFile
import Darwin
@testable import FilaFileOps
import Foundation

/// A real directory on a real filesystem, gone when the test is.
///
/// Everything in this suite runs against the actual syscalls. A file operation
/// that is only correct against a mock is not correct: `copyfile`'s xattr
/// handling, `renameat`'s refusal to cross a volume and `clonefile`'s ENOTSUP
/// are the behaviour under test, not incidental detail around it.
final class Scratch {
    /// Canonical, because everything in `FilaFileOps` canonicalises and a test
    /// that compared `/tmp/...` against `/private/tmp/...` would be testing the
    /// wrong thing.
    let root: String

    init(parent: String = "/private/tmp") {
        let name = "fila-tests-\(getpid())-\(UInt32.random(in: 0 ..< .max))"
        let created = parent + "/" + name
        precondition(mkdir(created, 0o755) == 0, "scratch directory: \(String(cString: strerror(errno)))")
        root = (try? FilaPath.resolve(created)) ?? created
    }

    deinit {
        removefile(root, nil, removefile_flags_t(REMOVEFILE_RECURSIVE))
    }

    func path(_ relative: String) -> String {
        root + "/" + relative
    }

    /// Creates every directory on the way, like `mkdir -p`.
    @discardableResult
    func directory(_ relative: String) -> String {
        var built = root
        for component in relative.split(separator: "/") {
            built += "/" + component
            precondition(mkdir(built, 0o755) == 0 || errno == EEXIST, "mkdir \(built)")
        }
        return built
    }

    @discardableResult
    func file(_ relative: String, contents: String = "fila", mode: mode_t = 0o644) -> String {
        let path = path(relative)
        let descriptor = open(path, O_CREAT | O_TRUNC | O_WRONLY, mode)
        precondition(descriptor >= 0, "open \(path): \(String(cString: strerror(errno)))")
        contents.withCString { _ = write(descriptor, $0, strlen($0)) }
        close(descriptor)
        return path
    }

    @discardableResult
    func link(_ relative: String, to target: String) -> String {
        let path = path(relative)
        precondition(symlink(target, path) == 0, "symlink \(path)")
        return path
    }
}

func metadata(of path: String) -> stat? {
    var found = stat()
    guard lstat(path, &found) == 0 else { return nil }
    return found
}

func exists(_ path: String) -> Bool {
    metadata(of: path) != nil
}

func permissions(of path: String) -> mode_t? {
    metadata(of: path).map { $0.st_mode & 0o7777 }
}

func hasFlag(_ flag: Int32, at path: String) -> Bool {
    (metadata(of: path)?.st_flags ?? 0) & UInt32(flag) != 0
}

func setExtendedAttribute(_ name: String, to value: String, at path: String) {
    let written = value.withCString { setxattr(path, name, $0, strlen($0), 0, XATTR_NOFOLLOW) }
    precondition(written == 0, "setxattr \(path): \(String(cString: strerror(errno)))")
}

func extendedAttribute(_ name: String, at path: String) -> String? {
    let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size + 1)
    let read = buffer.withUnsafeMutableBufferPointer { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
    guard read > 0 else { return nil }
    return String(cString: buffer)
}
