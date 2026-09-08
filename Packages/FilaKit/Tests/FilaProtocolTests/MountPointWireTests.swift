#if canImport(XPC)
    @testable import FilaProtocol
    import Testing
    import XPC

    struct MountPointWireTests {
        @Test("Mount metadata round-trips over XPC")
        func roundTrip() throws {
            let mount = MountPoint(path: "/Volumes/External Drive", device: "/dev/disk9s1", filesystem: "apfs", isReadOnly: true)
            #expect(try #require(MountPoint(decoding: mount.encoded())) == mount)
            #expect(MountPoint(decoding: xpc_dictionary_create(nil, nil, 0)) == nil)
        }
    }
#endif
