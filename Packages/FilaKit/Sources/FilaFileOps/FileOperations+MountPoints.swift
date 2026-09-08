import Darwin
import FilaProtocol

public extension FileOperations {
    /// A caller-owned buffer avoids getmntinfo's shared storage. NOWAIT reads
    /// cached mount metadata without waiting for removable or network volumes.
    func mountPoints() throws -> [MountPoint] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count >= 0 else { throw FilaFailure(errno: errno) }
        // Bound the daemon's allocation. A later refresh picks up mounts that
        // appear between the count and snapshot calls.
        guard count <= 1024 else { throw FilaFailure(errno: EOVERFLOW) }
        guard count > 0 else { return [] }
        var mounts: [statfs] = Array(repeating: statfs(), count: Int(count))
        let copied = mounts.withUnsafeMutableBytes { buffer in
            getfsstat(buffer.baseAddress?.assumingMemoryBound(to: statfs.self), Int32(buffer.count), MNT_NOWAIT)
        }
        guard copied >= 0 else { throw FilaFailure(errno: errno) }
        return mounts.prefix(min(Int(copied), mounts.count)).map {
            MountPoint(
                path: filaText($0.f_mntonname),
                device: filaText($0.f_mntfromname),
                filesystem: filaText($0.f_fstypename),
                isReadOnly: $0.f_flags & UInt32(MNT_RDONLY) != 0
            )
        }.sorted { $0.path < $1.path }
    }
}
