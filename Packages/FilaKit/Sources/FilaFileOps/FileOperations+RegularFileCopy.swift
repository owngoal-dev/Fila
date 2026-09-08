import Darwin
import FilaProtocol
import Foundation

public extension FileOperations {
    /// `clonefile(2)` on the same volume, `copyfile(3)` across one. Exclusive
    /// and never through a link, like every other write here.
    func copyRegularFile(at source: String, to destination: String) throws {
        let source = try FilaPath.canonical(source)
        let destination = try resolveForWrite(destination)
        let input = Darwin.open(source, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw FilaFailure(errno: errno, path: source) }
        defer { close(input) }
        var original = stat()
        guard fstat(input, &original) == 0 else { throw FilaFailure(errno: errno, path: source) }
        guard original.st_mode & S_IFMT == S_IFREG else { throw FilaFailure(errno: ENOTSUP, path: source) }

        let temporary = try resolveForWrite(
            FilaPath.join(FilaPath.directory(of: destination), ".fila-provider-" + UUID().uuidString)
        )
        var ownsTemporary = false
        do {
            // Clone the opened file, so both paths copy the same source inode.
            let cloned = fclonefileat(input, AT_FDCWD, temporary, 0) == 0
            ownsTemporary = cloned
            let output = Darwin.open(
                temporary,
                cloned ? O_RDONLY | O_NOFOLLOW : O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                0o600
            )
            guard output >= 0 else { throw FilaFailure(errno: errno, path: destination) }
            ownsTemporary = true
            defer { close(output) }
            if !cloned {
                guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                    throw FilaFailure(errno: errno, path: destination)
                }
            }
            var copied = stat()
            guard fstat(output, &copied) == 0 else { throw FilaFailure(errno: errno, path: destination) }
            let immovable = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
            if copied.st_flags & immovable != 0 {
                guard fchflags(output, copied.st_flags & ~immovable) == 0 else {
                    throw FilaFailure(errno: errno, path: destination)
                }
            }
            while fsync(output) != 0 {
                if errno != EINTR { throw FilaFailure(errno: errno, path: destination) }
            }
            guard renamex_np(temporary, destination, UInt32(RENAME_EXCL)) == 0 else {
                throw FilaFailure(errno: errno, path: destination)
            }
            ownsTemporary = false
            if copied.st_flags & immovable != 0 {
                guard fchflags(output, copied.st_flags) == 0 else { throw FilaFailure(errno: errno, path: destination) }
            }
        } catch {
            // Only a temporary created by this invocation is eligible for
            // cleanup. A collision never authorizes removing someone else's file.
            if ownsTemporary {
                _ = lchflags(temporary, 0)
                guard unlink(temporary) == 0 || errno == ENOENT else {
                    throw FilaFailure(errno: errno, path: temporary)
                }
            }
            throw error
        }
    }
}
