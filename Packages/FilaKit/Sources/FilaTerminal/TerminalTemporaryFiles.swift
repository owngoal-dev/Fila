import Darwin
import FilaFileOps
import FilaProtocol
import Foundation
import GhosttyTerminal

/// Library-generated configuration stays app-local, even with a root backend.
public enum TerminalTemporaryFiles {
    /// Call before creating any terminal controllers, and on application exit.
    /// Startup recovers configurations left behind when iOS kills the app.
    @MainActor
    public static func cleanup() throws {
        try cleanup(in: TerminalController.managedConfigDirectory)
    }

    static func cleanup(in directory: URL) throws {
        let path = try FilaPath.canonical(directory.path)
        // This parent also contains FileSession's local UUID workspaces. Create
        // it with their required permissions before the library can create it.
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            throw FilaFailure(errno: errno, path: path)
        }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FilaFailure(errno: errno, path: path) }
        guard let stream = fdopendir(descriptor) else {
            let failure = FilaFailure(errno: errno, path: path)
            close(descriptor)
            throw failure
        }
        defer { closedir(stream) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw FilaFailure(errno: errno, path: path) }
        guard metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o700 else {
            throw FilaFailure(errno: EPERM, path: path)
        }

        // Snapshot only direct configuration entries. Never remove this parent
        // or traverse UUID workspaces, including on a privileged app launch.
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw FilaFailure(errno: errno, path: path) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard name.hasPrefix("ghostty-config-"), name.hasSuffix(".conf"),
                  UUID(uuidString: String(name.dropFirst("ghostty-config-".count).dropLast(".conf".count))) != nil else { continue }
            names.append(name)
        }
        for name in names {
            // Unlink the entry itself: links never lead cleanup elsewhere, and
            // a directory with a configuration-like name cannot be recursed.
            if unlinkat(descriptor, name, 0) != 0, errno != ENOENT {
                throw FilaFailure(errno: errno, path: FilaPath.join(path, name))
            }
        }
    }
}
