import Foundation
import Testing
@testable import FilaFormats

@Suite("Mach-O inspection")
struct MachOInspectionTests {
    @Test("The enhanced inspector decodes real segments, commands and build versions")
    func inspectsSystemBinary() throws {
        try withDescriptor(reading: URL(fileURLWithPath: "/bin/ls")) { descriptor in
            let image = try MachOImage(descriptor: descriptor)
            for slice in image.slices {
                let details = try image.inspect(slice)
                #expect(details.loadCommands.contains { $0.hasPrefix("LC_SEGMENT_64") })
                #expect(details.segments.contains { $0.name == "__TEXT" && $0.protections.contains("x") })
                #expect(details.segments.flatMap(\.sections).contains("__text"))
                #expect(details.minimumOS != nil)
                #expect(details.sdk != nil)
                #expect(details.signingIdentifier != nil)
            }
        }
    }

    @Test("An open descriptor remains the source after the pathname disappears")
    func usesDescriptorAfterUnlink() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("image")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: url)
            try withDescriptor(reading: url) { descriptor in
                try FileManager.default.removeItem(at: url)
                let image = try MachOImage(descriptor: descriptor)
                let slice = try #require(image.slices.first)
                #expect(!(try image.inspect(slice)).segments.isEmpty)
            }
        }
    }

    @Test("Inspection does not read or allocate a large sparse payload")
    func sparsePayloadIsNotRead() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("sparse-image")
            // A valid empty 64-bit object header; the remainder has no commands
            // or signature and is deliberately a sparse four-gigabyte extent.
            let header = words([0xFEEDFACF, 0x0100000C, 0, 1, 0, 0, 0, 0])
            try header.write(to: url)
            let descriptor = open(url.path, O_RDWR)
            defer { if descriptor >= 0 { close(descriptor) } }
            #expect(descriptor >= 0)
            try #require(ftruncate(descriptor, 4 * 1_024 * 1_024 * 1_024) == 0)
            let image = try MachOImage(descriptor: descriptor)
            let slice = try #require(image.slices.first)
            let details = try image.inspect(slice)
            #expect(slice.byteCount == 4 * 1_024 * 1_024 * 1_024)
            #expect(details.loadCommands.isEmpty && details.segments.isEmpty)
        }
    }

    @Test("Truncated headers and command regions return errors")
    func rejectsTruncation() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("truncated")
            for bytes in [words([0xFEEDFACF, 0x0100000C, 0, 1, 1, 24, 0, 0]),
                          words([0xFEEDFACF, 0x0100000C, 0, 1, 0, 0, 0])] {
                try bytes.write(to: url)
                try withDescriptor(reading: url) { descriptor in
                    #expect(throws: FormatFailure.self) { try MachOImage(descriptor: descriptor) }
                }
            }
        }
    }

    @Test("Big-endian command decoding preserves distinct minimum and SDK versions")
    func bigEndianVersions() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("big-endian-object")
            let values: [UInt32] = [0xFEEDFACE, 18, 0, 1, 1, 16, 0,
                                    0x24, 16, 0x000A0900, 0x000A0A00]
            let data = values.reduce(into: Data()) { data, value in
                var big = value.bigEndian
                withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
            }
            try data.write(to: url)
            try withDescriptor(reading: url) { descriptor in
                let image = try MachOImage(descriptor: descriptor)
                let slice = try #require(image.slices.first)
                #expect(slice.isBigEndian)
                let details = try image.inspect(slice)
                #expect(details.platform == "macOS")
                #expect(details.minimumOS == "10.9.0")
                #expect(details.sdk == "10.10.0")
            }
        }
    }

    private func words(_ values: [UInt32]) -> Data {
        values.reduce(into: Data()) { data, value in
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
    }
}
