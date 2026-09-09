import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

@Suite("Atomic replace")
struct AtomicReplaceTests {
    let scratch = Scratch()
    let operations = FileOperations(bootstrapRoot: "")

    @Test("The original's metadata survives the swap")
    func carriesMetadataAcross() throws {
        let target = scratch.file("config.plist", contents: "old", mode: 0o640)
        setExtendedAttribute("wiki.qaq.fila.test", to: "kept", at: target)
        var times = [timeval(tv_sec: 1_000_000, tv_usec: 0), timeval(tv_sec: 1_000_000, tv_usec: 0)]
        #expect(lutimes(target, &times) == 0)
        #expect(lchflags(target, UInt32(UF_HIDDEN)) == 0)
        let original = try #require(metadata(of: target))

        let temporary = scratch.file("config.plist.new", contents: "new bytes", mode: 0o600)
        try operations.replaceItem(at: target, withTemporary: temporary)

        let replaced = try #require(metadata(of: target))
        #expect(replaced.st_mode & 0o7777 == 0o640)
        #expect(replaced.st_uid == original.st_uid)
        #expect(replaced.st_gid == original.st_gid)
        #expect(replaced.st_mtimespec.tv_sec == 1_000_000)
        #expect(replaced.st_flags & UInt32(UF_HIDDEN) != 0)
        #expect(extendedAttribute("wiki.qaq.fila.test", at: target) == "kept")
        #expect(replaced.st_size == 9)
        #expect(!exists(temporary))
    }

    @Test("A temporary in another directory is refused, not copied")
    func refusesCrossDirectory() {
        let target = scratch.file("config.plist", contents: "old")
        scratch.directory("elsewhere")
        let temporary = scratch.file("elsewhere/config.plist.new", contents: "new")

        let failure = #expect(throws: FilaFailure.self) {
            try operations.replaceItem(at: target, withTemporary: temporary)
        }
        #expect(failure?.code == .invalidRequest)
        #expect(exists(temporary))
        #expect(metadata(of: target)?.st_size == 3)
    }

    @Test("Saving a new file applies defaults before publishing it")
    func createsWhenNothingToReplace() throws {
        let temporary = scratch.file("brand-new.txt.tmp", contents: "hello")
        try operations.replaceItem(at: scratch.path("brand-new.txt"), withTemporary: temporary)
        #expect(metadata(of: scratch.path("brand-new.txt"))?.st_size == 5)
        #expect(metadata(of: scratch.path("brand-new.txt")).map { $0.st_mode & 0o7777 } == 0o777)
        #expect(metadata(of: scratch.path("brand-new.txt"))?.st_uid == (geteuid() == 0 ? 501 : getuid()))
        #expect(!exists(temporary))
    }

    @Test("Saving preserves the original access control list")
    func preservesACL() throws {
        let target = scratch.file("restricted.txt", contents: "old")
        var acl = acl_init(1)
        defer {
            if let acl {
                acl_free(UnsafeMutableRawPointer(acl))
            }
        }
        var entry: acl_entry_t?
        try #require(acl_create_entry(&acl, &entry) == 0)
        let access = try #require(entry)
        var identity = try #require(UUID(uuidString: "FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000")?.uuid)
        try #require(acl_set_tag_type(access, ACL_EXTENDED_ALLOW) == 0)
        try #require(acl_set_qualifier(access, &identity) == 0)
        try #require(acl_set_permset_mask_np(access, UInt64(ACL_READ_DATA.rawValue)) == 0)
        try #require(acl_set_file(target, ACL_TYPE_EXTENDED, acl) == 0)
        let original = try aclText(at: target)

        let temporary = scratch.file("restricted.txt.tmp", contents: "new")
        try operations.replaceItem(at: target, withTemporary: temporary)

        #expect(try aclText(at: target) == original)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "new")
    }

    @Test("Archive replacement applies its mode while retaining destination metadata")
    func replacementPermissions() throws {
        let target = scratch.file("script", contents: "old", mode: 0o600)
        setExtendedAttribute("wiki.qaq.fila.test", to: "kept", at: target)
        let temporary = scratch.file("script.tmp", contents: "new", mode: 0o600)
        try operations.replaceItem(at: target, withTemporary: temporary, permissions: 0o755)
        #expect((metadata(of: target)?.st_mode ?? 0) & 0o777 == 0o755)
        #expect(extendedAttribute("wiki.qaq.fila.test", at: target) == "kept")
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "new")
    }

    @Test("A save refuses a non-regular staging node and preserves the destination")
    func rejectsNonRegularTemporary() throws {
        let target = scratch.file("config", contents: "original")
        let temporary = scratch.path("config.tmp")
        try #require(mkfifo(temporary, 0o600) == 0)
        #expect(throws: FilaFailure.self) { try operations.replaceItem(at: target, withTemporary: temporary) }
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "original")
        #expect((metadata(of: temporary)?.st_mode ?? 0) & S_IFMT == S_IFIFO)
    }

    @Test("A directory at the name is refused as EISDIR, and keeps its entries and the temporary")
    func refusesDirectoryDestination() throws {
        let target = scratch.directory("config")
        let inside = scratch.file("config/kept", contents: "entry")
        let temporary = scratch.file("config.tmp", contents: "new bytes")

        // EISDIR is what the rename would have reported, and what the client
        // turns into `notEmpty`. Reaching `copyfile(3)` instead reports EINVAL.
        #expect(throws: FilaFailure(errno: EISDIR, path: target)) {
            try operations.replaceItem(at: target, withTemporary: temporary)
        }
        #expect((metadata(of: target)?.st_mode ?? 0) & S_IFMT == S_IFDIR)
        #expect(try String(contentsOfFile: inside, encoding: .utf8) == "entry")
        #expect(try String(contentsOfFile: temporary, encoding: .utf8) == "new bytes")
    }

    private func aclText(at path: String) throws -> String {
        let acl = try #require(acl_get_file(path, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let text = try #require(acl_to_text(acl, nil))
        defer { acl_free(text) }
        return String(cString: text)
    }
}
