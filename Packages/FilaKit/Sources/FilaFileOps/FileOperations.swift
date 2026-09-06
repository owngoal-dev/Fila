import Darwin
import FilaProtocol
import Foundation

/// Everything `filad` is allowed to do, as plain POSIX and nothing else.
///
/// There is no XPC in this module on purpose: this is the code that destroys
/// the user's filesystem when it is subtly wrong, and it has to be runnable
/// under `swift test` on a Mac with no daemon, no device and no app. The daemon
/// is a dispatcher over this type and holds no file logic of its own.
public struct FileOperations: Sendable {
    /// Where the jailbreak put us — randomized on roothide, `/var/jb` on
    /// rootless, empty on a rootful layout and on macOS. `FilaGuard` needs it
    /// and nothing here may guess at it, so it arrives from the daemon, which
    /// derives it from its own `proc_pidpath`.
    public let bootstrapRoot: String

    /// A boundary for a backend that serves one folder and nothing else: the
    /// File Provider extension. The daemon does not set it — a root file
    /// manager confined to its own bootstrap is not one — and a client
    /// override cannot widen it.
    let writableRoot: String?

    /// `fila-archive`, for a `.compress` or `.extract` job. Only the daemon
    /// sets it; the in-process backend runs the same job in its own process.
    public let archiveHelper: String?

    public init(bootstrapRoot: String, writableRoot: String? = nil, archiveHelper: String? = nil) {
        self.bootstrapRoot = bootstrapRoot
        self.writableRoot = writableRoot
        self.archiveHelper = archiveHelper
    }

    /// Where the trash lives: inside the bootstrap of a relocated daemon —
    /// roothide hides the jailbreak's files there, and the data volume is one
    /// volume either way — or at the volume's own root otherwise.
    func trashBase(volumeMountPoint: String) throws -> String {
        if let writableRoot { return try FilaPath.resolve(writableRoot) }
        return bootstrapRoot.isEmpty ? volumeMountPoint : try FilaPath.resolve(bootstrapRoot)
    }

    /// Resolve the parent, preserving the final node for no-follow syscalls.
    /// A missing destination is valid; a parent link outside the install root
    /// is not. Resolve the root as well so aliases share the same boundary.
    func resolveForWrite(_ path: String, changesInode: Bool = false) throws -> String {
        let resolved = try FilaPath.canonical(path)
        if let writableRoot {
            let root = try FilaPath.resolve(writableRoot)
            let rootComponents = URL(fileURLWithPath: root).pathComponents
            let components = URL(fileURLWithPath: resolved).pathComponents
            guard components.starts(with: rootComponents) else {
                throw FilaFailure(errno: EROFS, path: resolved)
            }
            if changesInode {
                // A second name could be outside the root. Directory-entry
                // changes remain safe, but bytes and attributes are shared.
                var metadata = stat()
                if lstat(resolved, &metadata) == 0 {
                    guard metadata.st_mode & S_IFMT == S_IFDIR || metadata.st_nlink <= 1 else {
                        throw FilaFailure(errno: EROFS, path: resolved)
                    }
                } else if Darwin.errno != ENOENT {
                    throw FilaFailure(errno: Darwin.errno, path: resolved)
                }
            }
        }
        return resolved
    }

    /// Canonicalise, then refuse if the guard says this node may not be
    /// destroyed.
    ///
    /// Every operation that deletes, moves away or replaces a node comes
    /// through here, and nothing else in the module asks the guard. One owner,
    /// because a second caller that forgot to canonicalise first is exactly the
    /// bypass the guard exists to not have.
    public func resolveForDestruction(_ path: String, overrideGuard: Bool = false) throws -> String {
        let resolved = try resolveForWrite(path)
        if let writableRoot {
            // Everything inside the relocated bootstrap is editable. The
            // bootstrap node itself must survive, including with an override.
            guard resolved != (try FilaPath.resolve(writableRoot)) else {
                throw FilaFailure(code: .protectedPath, path: resolved)
            }
            return resolved
        }
        for spelling in guardedSpellings(of: path, canonical: resolved) {
            guard FilaGuard.isDestructionProtected(spelling, bootstrapRoot: bootstrapRoot) else { continue }
            // The override is the "I know what I am doing" switch, and it stops
            // at the nodes with no recovery path on a phone: losing the volume
            // root or the bootstrap takes the jailbreak, the app, and any means
            // of putting either back.
            guard overrideGuard, !isIrrecoverable(spelling) else {
                throw FilaFailure(code: .protectedPath, path: resolved)
            }
        }
        return resolved
    }

    /// Both names a node can be destroyed under.
    ///
    /// `FilaPath.canonical` leaves the last component unresolved, because
    /// deleting a link has to delete the link. That is also what makes `/var`
    /// arrive spelled `/var` — and the guard's list knows that directory as
    /// `/private/var`, so on its own the canonical spelling would let
    /// `removefile("/var")` unlink the symlink the device boots through. Losing
    /// the link is losing the directory, so what the link *names* is put
    /// through the guard as well.
    ///
    /// The price is refusing to delete a symlink somebody made that happens to
    /// point at a protected node. That is a false positive the override
    /// releases; the other way round there is no undo.
    private func guardedSpellings(of path: String, canonical: String) -> [String] {
        guard let target = try? FilaPath.resolve(path), target != canonical else { return [canonical] }
        return [canonical, target]
    }

    /// The guard's verdict for a path that has already been canonicalised.
    /// Shipped in `FileDetails` so the app can grey a menu item out; the app is
    /// untrusted and the daemon asks again when the operation arrives.
    public func isDestructionProtected(_ canonicalPath: String) -> Bool {
        if writableRoot != nil {
            return (try? resolveForDestruction(canonicalPath)) == nil
        }
        return FilaGuard.isDestructionProtected(canonicalPath, bootstrapRoot: bootstrapRoot)
    }

    /// The nodes the override does not release.
    ///
    /// The volume root, the bootstrap root, and every directory that *contains*
    /// the bootstrap root: `/var/jb` is gone the moment `/private/var` is, so
    /// refusing only the exact path would leave the hole the refusal exists to
    /// close.
    private func isIrrecoverable(_ canonicalPath: String) -> Bool {
        let target = FilaGuard.normalize(canonicalPath)
        if target == "/" { return true }
        let bootstrap = FilaGuard.normalize(bootstrapRoot)
        guard bootstrap != "/" else { return false }
        return target == bootstrap || FilaGuard.isAncestor(target, of: bootstrap)
    }
}
