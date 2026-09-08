import Darwin
@testable import FilaProtocol
import Foundation
import Testing

// The guard is pure logic and it is the branch that, wrong, bricks a phone. It
// runs on the Mac against a real filesystem: no device, no simulator.

@Suite("Path normalisation")
struct NormalizeTests {
    @Test("Collapses to an absolute, separator-clean path")
    func normalizes() {
        #expect(FilaGuard.normalize("/") == "/")
        #expect(FilaGuard.normalize("") == "/")
        #expect(FilaGuard.normalize("/private//var/") == "/private/var")
        #expect(FilaGuard.normalize("/private/./var") == "/private/var")
        #expect(FilaGuard.normalize("/private/var/mobile/..") == "/private/var")
        #expect(FilaGuard.normalize("/../..") == "/")
        #expect(FilaGuard.normalize("private/var") == "/private/var")
    }

    @Test("Ancestry is by component, not by string prefix")
    func ancestry() {
        #expect(FilaGuard.isAncestor("/private", of: "/private/var"))
        #expect(!FilaGuard.isAncestor("/priv", of: "/private/var"))
        #expect(!FilaGuard.isAncestor("/private/var", of: "/private/var"))
        #expect(FilaGuard.isAncestor("/", of: "/usr"))
        #expect(!FilaGuard.isAncestor("/", of: "/"))
    }
}

@Suite("Destruction guard")
struct DestructionGuardTests {
    private let bootstrap = "/var/jb"

    private func isProtected(_ path: String) -> Bool {
        FilaGuard.isDestructionProtected(path, bootstrapRoot: bootstrap)
    }

    @Test("Refuses the nodes that keep the device bootable")
    func protectsBootableNodes() {
        #expect(isProtected("/"))
        #expect(isProtected("/private/var/mobile"))
        #expect(isProtected("/private"))
        #expect(isProtected("/System"))
        #expect(isProtected(bootstrap))
        #expect(isProtected(bootstrap + "/usr"))
    }

    @Test("Leaves everything inside them editable — which is the point of the app")
    func allowsContents() {
        #expect(!isProtected("/private/var/mobile/Media/DCIM"))
        #expect(!isProtected("/System/Library/CoreServices/SpringBoard.app"))
        #expect(!isProtected(bootstrap + "/usr/bin/dpkg"))
        #expect(!isProtected("/private/var/mobile/Documents"))
    }

    @Test("Traversal is not a way around the list")
    func resistsTraversal() {
        #expect(isProtected("/private/var/mobile/.."))
        #expect(isProtected("/private/var/mobile/Media/../.."))
    }

    @Test("A rootful layout has no bootstrap root of its own")
    func rootfulLayout() {
        #expect(FilaGuard.isDestructionProtected("/usr", bootstrapRoot: ""))
    }
}

@Suite("Filesystem assumptions the guard depends on")
struct CanonicalPathTests {
    /// The guard compares canonical paths and trusts `realpath(3)` to have
    /// collapsed the symlinks Apple platforms ship. If that stopped holding,
    /// every entry under `/private` would be bypassable by spelling the path
    /// `/var/...` instead.
    @Test("/var and /etc resolve into /private")
    func appleSymlinksResolve() {
        #expect(realpathString("/var") == "/private/var")
        #expect(realpathString("/etc") == "/private/etc")
    }

    /// A symlink pointing at a protected directory must not launder it: the
    /// daemon resolves before it decides, so the resolved path is what the
    /// guard sees.
    @Test("A symlink to a protected directory does not launder it")
    func symlinkDoesNotLaunder() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        // `/usr` rather than `/private/var/mobile`: these run on macOS, and
        // realpath(3) returns nothing for a link whose target does not exist.
        let link = scratch + "/looks-harmless"
        #expect(symlink("/usr", link) == 0, "symlink failed: \(String(cString: strerror(errno)))")

        #expect(!FilaGuard.isDestructionProtected(link, bootstrapRoot: "/var/jb"))
        #expect(FilaGuard.isDestructionProtected(realpathString(link) ?? link, bootstrapRoot: "/var/jb"))
    }
}

// MARK: - Support

func makeScratchDirectory() throws -> String {
    var template = Array((NSTemporaryDirectory() + "fila-tests.XXXXXX").utf8CString)
    guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
        throw FilaFailure(code: .operationFailed, systemError: errno)
    }
    return String(cString: made)
}

func realpathString(_ path: String) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let resolved = path.withCString { source in
        buffer.withUnsafeMutableBufferPointer { realpath(source, $0.baseAddress) }
    }
    return resolved.map { _ in String(cString: buffer) }
}
