import Foundation
import MachOKit

extension MachOImage {
    /// Display values copied out of bounded structural snapshots. No MachOKit
    /// pointer, mapped file, URL opener or lazy sequence escapes this adapter.
    public struct Inspection: Sendable {
        public var flags: [String] = []
        public var loadCommands: [String] = []
        public var runpaths: [String] = []
        public var segments: [Segment] = []
        public var platform: String?
        public var minimumOS: String?
        public var sdk: String?
        public var sourceVersion: String?
        public var entryOffset: UInt64?
        public var symbolCount: UInt32?
        public var encryptionMethod: UInt32?
        public var encryptedByteCount: UInt32?
        public var signingIdentifier: String?
        public var teamIdentifier: String?
        public var isAdHoc: Bool?
    }

    public struct Segment: Sendable {
        public var name: String
        public var virtualAddress: UInt64
        public var virtualSize: UInt64
        public var fileOffset: UInt64
        public var fileSize: UInt64
        public var protections: String
        public var sections: [String]
    }

    /// The existing parser owns slice bounds and signature locations. MachOKit
    /// supplies typed load commands and the complete command/flag vocabulary.
    /// Only its fixed-layout decoders are called, after validating their size.
    /// Its URL-based MachOFile and live-process MachOImage are deliberately not
    /// used: neither is a substitute for the descriptor the daemon handed back.
    public func inspect(_ slice: Slice) throws -> Inspection {
        guard slices.contains(slice) else { throw FormatFailure.damaged("this architecture is not in the file") }
        let headerSize = slice.isSixtyFourBit ? 32 : 28
        let header = try reader.read(at: slice.offset, count: headerSize)
        let flags: UInt32 = try header.integer(at: 24, bigEndian: slice.isBigEndian)
        let count: UInt32 = try header.integer(at: 16, bigEndian: slice.isBigEndian)
        let length: UInt32 = try header.integer(at: 20, bigEndian: slice.isBigEndian)
        guard count <= 16_384, UInt64(count) * 8 <= length,
              Int64(length) <= min(slice.byteCount - Int64(headerSize), 16 * 1_024 * 1_024) else {
            throw FormatFailure.damaged("its load commands could not be read")
        }
        let data = try reader.read(at: slice.offset + Int64(headerSize), count: Int(length))
        var result = Inspection()
        result.flags = MachHeader.Flags.Bit.allCases.filter { flags & $0.rawValue != 0 }.map(\.description)
        var cursor = 0
        for _ in 0 ..< count {
            try Task.checkCancellation()
            guard data.count - cursor >= 8 else { throw FormatFailure.damaged("its load command list is truncated") }
            let command: UInt32 = try data.integer(at: cursor, bigEndian: slice.isBigEndian)
            let size = Int(try data.integer(at: cursor + 4, bigEndian: slice.isBigEndian) as UInt32)
            guard size >= 8, size % (slice.isSixtyFourBit ? 8 : 4) == 0, size <= data.count - cursor else {
                throw FormatFailure.damaged("part of its header is the wrong size")
            }
            let bytes = data.subdata(in: cursor ..< cursor + size)
            let name = MachOKit.LoadCommandType(rawValue: command)?.description ?? String(format: "0x%08X", command)
            result.loadCommands.append("\(name) · \(size) B")
            if command == 0x8000_001C {
                guard size >= 12 else { throw FormatFailure.damaged("its runpaths could not be read") }
                let relative: UInt32 = try bytes.integer(at: 8, bigEndian: slice.isBigEndian)
                guard relative >= 12, relative < size else { throw FormatFailure.damaged("a runpath entry is invalid") }
                result.runpaths.append(try Self.terminatedString(bytes, at: Int(relative), limit: size))
            }
            if let minimum = Self.decodedCommandSizes[command] {
                guard size >= minimum else { throw FormatFailure.damaged("a load command is truncated") }
                // One fully validated command per iterator. Unknown commands
                // never enter the upstream pointer conversion dispatch.
                var iterator = MachOFile.LoadCommands.Iterator(data: bytes, numberOfCommands: 1, isSwapped: slice.isBigEndian)
                guard let decoded = iterator.next() else { throw FormatFailure.damaged("a load command could not be read") }
                try Self.apply(decoded, bytes: bytes, slice: slice, into: &result)
            }
            cursor += size
        }
        guard cursor == data.count else { throw FormatFailure.damaged("its load commands do not match the header") }
        try readSigningIdentity(slice, into: &result)
        return result
    }

    private static let decodedCommandSizes: [UInt32: Int] = [
        0x1: 56, 0x19: 72, // segments
        0x2: 24, // symbol table
        0x21: 20, 0x2C: 24, // encryption info
        0x24: 16, 0x25: 16, 0x2F: 16, 0x30: 16, // legacy OS versions
        0x32: 24, 0x2A: 16, 0x8000_0028: 24, // build/source versions, entry point
    ]

    private static func apply(_ command: MachOKit.LoadCommand, bytes: Data, slice: Slice, into result: inout Inspection) throws {
        switch command {
        case let .segment64(segment):
            result.segments.append(try segmentSummary(
                name: fixedString(bytes, at: 8, count: 16), address: segment.layout.vmaddr,
                size: segment.layout.vmsize, offset: segment.layout.fileoff, fileSize: segment.layout.filesize,
                protection: segment.initialProtection, sections: segment.layout.nsects,
                bytes: bytes, headerSize: 72, sectionSize: 80, slice: slice
            ))
        case let .segment(segment):
            result.segments.append(try segmentSummary(
                name: fixedString(bytes, at: 8, count: 16), address: UInt64(segment.layout.vmaddr),
                size: UInt64(segment.layout.vmsize), offset: UInt64(segment.layout.fileoff), fileSize: UInt64(segment.layout.filesize),
                protection: segment.initialProtection, sections: segment.layout.nsects,
                bytes: bytes, headerSize: 56, sectionSize: 68, slice: slice
            ))
        case let .buildVersion(version):
            guard UInt64(version.layout.ntools) * 8 <= bytes.count - 24 else { throw FormatFailure.damaged("its version information is truncated") }
            result.platform = version.platform.description
            result.minimumOS = version.minos.description
            result.sdk = version.sdk.description
        case let .versionMinMacosx(version), let .versionMinIphoneos(version), let .versionMinTvos(version), let .versionMinWatchos(version):
            result.minimumOS = version.version.description
            // MachOKit 0.52.2's legacy sdk accessor reads the version field;
            // preserve the actual SDK word rather than repeating the minimum OS.
            result.sdk = Self.versionString(version.layout.sdk)
            switch command {
            case .versionMinMacosx: result.platform = "macOS"
            case .versionMinIphoneos: result.platform = "iOS"
            case .versionMinTvos: result.platform = "tvOS"
            default: result.platform = "watchOS"
            }
        case let .encryptionInfo(info):
            result.encryptionMethod = info.layout.cryptid
            result.encryptedByteCount = info.layout.cryptsize
        case let .encryptionInfo64(info):
            result.encryptionMethod = info.layout.cryptid
            result.encryptedByteCount = info.layout.cryptsize
        case let .sourceVersion(version): result.sourceVersion = version.version.description
        case let .main(entry):
            guard entry.layout.entryoff < slice.byteCount else { throw FormatFailure.damaged("its entry offset is outside this architecture") }
            result.entryOffset = entry.layout.entryoff
        case let .symtab(table):
            let symbolSize: UInt64 = slice.isSixtyFourBit ? 16 : 12
            guard UInt64(table.layout.symoff) <= slice.byteCount,
                  UInt64(table.layout.nsyms) * symbolSize <= UInt64(slice.byteCount) - UInt64(table.layout.symoff),
                  UInt64(table.layout.stroff) <= slice.byteCount,
                  UInt64(table.layout.strsize) <= UInt64(slice.byteCount) - UInt64(table.layout.stroff) else {
                throw FormatFailure.damaged("its symbols are outside this architecture")
            }
            result.symbolCount = table.layout.nsyms
        default: break
        }
    }

    private static func segmentSummary(name: String, address: UInt64, size: UInt64, offset: UInt64,
                                       fileSize: UInt64, protection: VMProtection, sections: UInt32,
                                       bytes: Data, headerSize: Int, sectionSize: Int, slice: Slice) throws -> Segment {
        guard offset <= slice.byteCount, fileSize <= UInt64(slice.byteCount) - offset,
              UInt64(sections) * UInt64(sectionSize) <= bytes.count - headerSize else {
            throw FormatFailure.damaged("a segment or section is outside this architecture")
        }
        let names = (0 ..< Int(sections)).map { fixedString(bytes, at: headerSize + $0 * sectionSize, count: 16) }
        let permissions = (protection.contains(.read) ? "r" : "-")
            + (protection.contains(.write) ? "w" : "-") + (protection.contains(.execute) ? "x" : "-")
        return Segment(name: name, virtualAddress: address, virtualSize: size, fileOffset: offset,
                       fileSize: fileSize, protections: permissions, sections: names)
    }

    private static func fixedString(_ bytes: Data, at offset: Int, count: Int) -> String {
        String(decoding: bytes[offset ..< offset + count].prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func terminatedString(_ bytes: Data, at offset: Int, limit: Int) throws -> String {
        guard offset >= 0, offset < limit, limit <= bytes.count,
              let end = bytes[offset ..< limit].firstIndex(of: 0) else {
            throw FormatFailure.damaged("a name inside it is truncated")
        }
        return String(decoding: bytes[offset ..< end], as: UTF8.self)
    }

    private static func versionString(_ value: UInt32) -> String {
        "\(value >> 16).\((value >> 8) & 255).\(value & 255)"
    }

    /// Read the superblob index and fixed CodeDirectory fields, then bounded
    /// identifier strings. Page hashes are never loaded into memory.
    private func readSigningIdentity(_ slice: Slice, into result: inout Inspection) throws {
        guard let signature = slice.signature, signature.byteCount >= 12 else { return }
        let head = try reader.read(at: signature.offset, count: 12)
        guard try head.bigEndian(at: 0) as UInt32 == 0xFADE_0CC0 else { return }
        let length = Int64(try head.bigEndian(at: 4) as UInt32)
        let count = Int(try head.bigEndian(at: 8) as UInt32)
        guard length <= signature.byteCount, count <= 64, 12 + count * 8 <= length else {
            throw FormatFailure.damaged("its code signature is invalid")
        }
        let index = try reader.read(at: signature.offset + 12, count: count * 8)
        for number in 0 ..< count {
            let offset = Int64(try index.bigEndian(at: number * 8 + 4) as UInt32)
            guard offset >= 12 + count * 8, offset <= length - 8 else { throw FormatFailure.damaged("its code signature is invalid") }
            let blobHeader = try reader.read(at: signature.offset + offset, count: 8)
            guard try blobHeader.bigEndian(at: 0) as UInt32 == 0xFADE_0C02 else { continue }
            let blobLength = Int64(try blobHeader.bigEndian(at: 4) as UInt32)
            guard blobLength >= 44, blobLength <= length - offset else { throw FormatFailure.damaged("its code signature is truncated") }
            let directory = try reader.read(at: signature.offset + offset, count: Int(min(blobLength, 52)))
            let version: UInt32 = try directory.bigEndian(at: 8)
            let flags: UInt32 = try directory.bigEndian(at: 12)
            let identifier = Int64(try directory.bigEndian(at: 20) as UInt32)
            func string(_ relative: Int64) throws -> String? {
                guard relative != 0 else { return nil }
                let minimum: Int64 = version >= 0x20200 ? 52 : 44
                guard relative >= minimum, relative < blobLength else { throw FormatFailure.damaged("its signing identifier is invalid") }
                let bytes = try reader.read(at: signature.offset + offset + relative, count: Int(min(4096, blobLength - relative)))
                return try Self.terminatedString(bytes, at: 0, limit: bytes.count)
            }
            result.isAdHoc = flags & 2 != 0
            result.signingIdentifier = try string(identifier)
            if version >= 0x20200 {
                guard directory.count >= 52 else { throw FormatFailure.damaged("its team identifier is truncated") }
                result.teamIdentifier = try string(Int64(try directory.bigEndian(at: 48) as UInt32))
            }
            return
        }
    }
}
