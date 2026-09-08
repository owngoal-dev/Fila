@testable import FilaFormats
import Foundation
import Testing

/// Parsed against the binaries the machine already has. `/bin/ls` is a fat
/// binary on every Mac and a thin one on a device, which is exactly the pair of
/// shapes the parser has to get right, and no fixture reproduces a real code
/// signature.
@Suite("Mach-O")
struct MachOTests {
    @Test("/bin/ls parses: its architectures, its dylibs, its UUID and its signature")
    func parsesSystemBinary() throws {
        try withDescriptor(reading: URL(fileURLWithPath: "/bin/ls")) { descriptor in
            let image = try MachOImage(descriptor: descriptor)
            #expect(!image.slices.isEmpty)

            for slice in image.slices {
                #expect(slice.fileType == .executable)
                #expect(slice.isSixtyFourBit)
                #expect(!slice.isBigEndian)
                #expect(slice.uuid != nil)
                #expect(slice.isCodeSigned)
                #expect(!slice.isEncrypted)
                #expect(slice.linkedLibraries.contains { $0.hasSuffix("libSystem.B.dylib") })
                #expect(slice.installName == nil)
            }
            // Every architecture Apple ships is named, never numbered.
            #expect(image.slices.allSatisfy { !$0.architecture.hasPrefix("cputype") })
        }
    }

    @Test("The entitlements come back out of the code signature as a property list")
    func readsEntitlements() throws {
        let url = URL(fileURLWithPath: "/usr/libexec/lsd")
        try #require(FileManager.default.fileExists(atPath: url.path))
        try withDescriptor(reading: url) { descriptor in
            let image = try MachOImage(descriptor: descriptor)
            let slice = try #require(image.slices.first)
            let entitlements = try #require(try image.entitlements(of: slice))
            guard case let .dictionary(claims) = entitlements.root else {
                Issue.record("entitlements are not a dictionary")
                return
            }
            #expect(!claims.isEmpty)
        }
    }

    @Test("A binary with no entitlements is nil, not a failure — most of a jailbroken filesystem is that")
    func toleratesNoEntitlements() throws {
        try withDescriptor(reading: URL(fileURLWithPath: "/bin/ls")) { descriptor in
            let image = try MachOImage(descriptor: descriptor)
            for slice in image.slices {
                #expect(try image.entitlements(of: slice) == nil)
            }
        }
    }

    @Test("Anything that is not a Mach-O is not recognised")
    func rejectsOtherFiles() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("text.txt")
            try Data("this is not a binary".utf8).write(to: url)
            try withDescriptor(reading: url) { descriptor in
                #expect(throws: FormatFailure.notRecognised) { try MachOImage(descriptor: descriptor) }
            }
        }
    }
}
