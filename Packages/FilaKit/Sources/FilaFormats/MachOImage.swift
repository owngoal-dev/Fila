import Foundation

/// A Mach-O binary, read through a descriptor and never mapped.
///
/// Two reads answer nearly every question: the header, and the load-command
/// region it declares. Both are kilobytes even for a binary that is hundreds of
/// megabytes, which is what lets the properties screen show the architectures
/// and the entitlements of `/usr/libexec/something` without the app growing by
/// the size of the file it is inspecting.
///
/// The constants are spelled out rather than taken from `<mach-o/loader.h>` on
/// purpose. The file is decoded byte by byte with an explicit byte order — the
/// values are part of the parser, not of whatever the host happens to define,
/// and a big-endian binary read on a little-endian phone has to work.
public struct MachOImage: Sendable {
    /// `MH_*`, the header's `filetype`.
    public enum FileType: UInt32, Sendable, Hashable {
        case object = 1
        case executable = 2
        case fixedVMLibrary = 3
        case core = 4
        case preload = 5
        case dynamicLibrary = 6
        case dynamicLinker = 7
        case bundle = 8
        case dynamicLibraryStub = 9
        case debugSymbols = 10
        case kernelExtension = 11
        case fileSet = 12
    }

    /// Where a slice's code signature sits inside the file. Kept so
    /// `entitlements(of:)` can go straight there instead of re-walking the
    /// load commands, and internal because an absolute file offset is not
    /// something a caller has any use for.
    struct SignatureLocation: Sendable, Hashable {
        var offset: Int64
        var byteCount: Int64
    }

    /// One architecture's worth of Mach-O. A thin binary has exactly one.
    public struct Slice: Sendable, Hashable {
        public var cpuType: Int32
        public var cpuSubtype: Int32
        /// What `lipo -info` would print: `arm64e`, `x86_64`, `armv7`.
        public var architecture: String
        public var fileType: FileType?
        public var isSixtyFourBit: Bool
        /// A binary for a big-endian target — a PowerPC or a classic ARM BE
        /// kernel cache. Rare, but the difference between parsing it and
        /// reading every length field backwards.
        public var isBigEndian: Bool
        /// Where the slice starts in the file. Zero for a thin binary, and the
        /// number every offset in its load commands is relative to.
        public var offset: Int64
        public var byteCount: Int64
        /// `LC_UUID` — what a crash report and a dSYM are matched by.
        public var uuid: UUID?
        /// `LC_LOAD_DYLIB` and its weak, re-export and upward variants, in the
        /// order the linker recorded them.
        public var linkedLibraries: [String]
        /// `LC_ID_DYLIB`: a dylib's own install name, and the thing that
        /// decides whether a tweak actually gets loaded.
        public var installName: String?
        /// `LC_ENCRYPTION_INFO*` with a non-zero `cryptid`: the App Store's
        /// FairPlay wrapper is still on it, so the `__TEXT` bytes on disk are
        /// ciphertext and no disassembler will make sense of them. This is the
        /// question every "is this decrypted?" workflow is actually asking.
        public var isEncrypted: Bool
        public var isCodeSigned: Bool

        var signature: SignatureLocation?
    }

    public let slices: [Slice]

    /// A fat binary — several architectures in one file, behind a header that
    /// is big-endian regardless of what any of them target.
    public let isUniversal: Bool

    let reader: DescriptorReader

    public init(descriptor: Int32) throws {
        let reader = try DescriptorReader(descriptor: descriptor)
        self.reader = reader

        let magic = try reader.readUpTo(at: 0, count: 4)
        guard magic.count == 4 else { throw FormatFailure.notRecognised }

        switch [UInt8](magic) {
        case [0xCA, 0xFE, 0xBA, 0xBE]:
            (slices, isUniversal) = (try Self.fatSlices(reader, bigEndian: true, is64: false), true)
        case [0xBE, 0xBA, 0xFE, 0xCA]:
            (slices, isUniversal) = (try Self.fatSlices(reader, bigEndian: false, is64: false), true)
        case [0xCA, 0xFE, 0xBA, 0xBF]:
            (slices, isUniversal) = (try Self.fatSlices(reader, bigEndian: true, is64: true), true)
        case [0xBF, 0xBA, 0xFE, 0xCA]:
            (slices, isUniversal) = (try Self.fatSlices(reader, bigEndian: false, is64: true), true)
        default: (slices, isUniversal) = ([try Self.slice(reader, at: 0, byteCount: reader.byteCount)], false)
        }
    }

    /// The entitlements embedded in a slice's code signature.
    ///
    /// Nil when the slice is unsigned or signed without them — an ad-hoc `ldid`
    /// signature with no entitlements is the normal state of half the binaries
    /// on a jailbroken device, and not an error. The blob is found through the
    /// signature's own index, so the only bytes read are the index and the
    /// entitlements themselves: a code signature on a large binary is mostly
    /// page hashes, and there is no reason to pull megabytes of those in to
    /// find a two-kilobyte plist.
    public func entitlements(of slice: Slice, maximumByteCount: Int64 = 128 * 1_024) throws -> PropertyListDocument? {
        guard let signature = slice.signature, signature.byteCount >= 12 else { return nil }

        let index = try reader.readUpTo(at: signature.offset, count: min(Int(signature.byteCount), 12 + 64 * 8))
        let superBlobMagic: UInt32 = try index.bigEndian(at: 0)
        guard superBlobMagic == Self.embeddedSignatureMagic else { return nil }
        let count: UInt32 = try index.bigEndian(at: 8)
        // A superblob holds a handful of blobs; a count in the thousands is a
        // corrupt length being used to make us read the whole file.
        guard count <= 64 else { throw FormatFailure.damaged("its code signature could not be read") }

        for position in 0 ..< Int(count) {
            let blobOffset: UInt32 = try index.bigEndian(at: 12 + position * 8 + 4)
            guard Int64(blobOffset) + 8 <= signature.byteCount else { continue }

            let header = try reader.read(at: signature.offset + Int64(blobOffset), count: 8)
            let blobMagic: UInt32 = try header.bigEndian(at: 0)
            guard blobMagic == Self.entitlementsMagic else { continue }

            let length: UInt32 = try header.bigEndian(at: 4)
            guard length > 8, Int64(blobOffset) + Int64(length) <= signature.byteCount else {
                throw FormatFailure.damaged("its entitlements are truncated")
            }
            guard Int64(length) - 8 <= maximumByteCount else {
                throw FormatFailure.tooLarge(byteCount: Int64(length) - 8, limit: maximumByteCount)
            }
            let plist = try reader.read(at: signature.offset + Int64(blobOffset) + 8, count: Int(length) - 8)
            return try PropertyListDocument(data: plist)
        }
        return nil
    }

    private static func fatSlices(_ reader: DescriptorReader, bigEndian: Bool, is64: Bool) throws -> [Slice] {
        let header = try reader.read(at: 0, count: 8)
        let count: UInt32 = try header.integer(at: 4, bigEndian: bigEndian)
        // `lipo` itself refuses more than a handful; anything beyond this is a
        // length field being used to make us allocate.
        guard count > 0, count <= 8 else { throw FormatFailure.damaged("its list of architectures could not be read") }

        let entrySize = is64 ? 32 : 20
        let table = try reader.read(at: 8, count: Int(count) * entrySize)
        var remainingCommands = maximumLoadCommandByteCount

        return try (0 ..< Int(count)).map { index in
            let base = index * entrySize
            let offset: Int64, byteCount: Int64
            if is64 {
                guard
                    let checkedOffset = Int64(exactly: try table.integer(at: base + 8, bigEndian: bigEndian) as UInt64),
                    let checkedCount = Int64(exactly: try table.integer(at: base + 16, bigEndian: bigEndian) as UInt64)
                else {
                    throw FormatFailure.damaged("one of its architectures is invalid")
                }
                offset = checkedOffset
                byteCount = checkedCount
            } else {
                offset = Int64(try table.integer(at: base + 8, bigEndian: bigEndian) as UInt32)
                byteCount = Int64(try table.integer(at: base + 12, bigEndian: bigEndian) as UInt32)
            }
            guard offset >= Int64(8 + Int(count) * entrySize) else {
                throw FormatFailure.damaged("its architecture list is invalid")
            }
            let header = try reader.read(at: offset, count: 24)
            let magic: UInt32 = try header.littleEndian(at: 0)
            let swapped = magic == 0xCEFAEDFE || magic == 0xCFFAEDFE
            let commands: UInt32 = try header.integer(at: 20, bigEndian: swapped)
            guard Int64(commands) <= remainingCommands else {
                throw FormatFailure.tooLarge(
                    byteCount: maximumLoadCommandByteCount + 1,
                    limit: maximumLoadCommandByteCount
                )
            }
            remainingCommands -= Int64(commands)
            return try slice(reader, at: offset, byteCount: byteCount)
        }
    }

    private static func slice(_ reader: DescriptorReader, at offset: Int64, byteCount: Int64) throws -> Slice {
        guard offset >= 0, offset <= reader.byteCount, byteCount > 0, byteCount <= reader.byteCount - offset else {
            throw FormatFailure.damaged("one of its architectures is missing from the file")
        }

        let header = try reader.read(at: offset, count: Int(min(byteCount, 32)))
        guard header.count >= 28 else { throw FormatFailure.notRecognised }

        let is64: Bool, bigEndian: Bool
        switch [UInt8](header.prefix(4)) {
        case [0xCF, 0xFA, 0xED, 0xFE]: (is64, bigEndian) = (true, false)
        case [0xCE, 0xFA, 0xED, 0xFE]: (is64, bigEndian) = (false, false)
        case [0xFE, 0xED, 0xFA, 0xCF]: (is64, bigEndian) = (true, true)
        case [0xFE, 0xED, 0xFA, 0xCE]: (is64, bigEndian) = (false, true)
        default: throw FormatFailure.notRecognised
        }
        let headerByteCount = is64 ? 32 : 28
        guard byteCount >= headerByteCount else { throw FormatFailure.damaged("its Mach-O header is truncated") }
        func headerWord(_ at: Int) throws -> UInt32 { try header.integer(at: at, bigEndian: bigEndian) }

        let cpuType = Int32(bitPattern: try headerWord(4))
        let cpuSubtype = Int32(bitPattern: try headerWord(8))
        var slice = Slice(
            cpuType: cpuType,
            cpuSubtype: cpuSubtype,
            architecture: architectureName(cpuType: cpuType, cpuSubtype: cpuSubtype),
            fileType: FileType(rawValue: try headerWord(12)),
            isSixtyFourBit: is64,
            isBigEndian: bigEndian,
            offset: offset,
            byteCount: byteCount,
            uuid: nil,
            linkedLibraries: [],
            installName: nil,
            isEncrypted: false,
            isCodeSigned: false
        )

        let commandCount = try headerWord(16)
        let commandsByteCount = try headerWord(20)
        guard Int64(commandsByteCount) <= min(byteCount - Int64(headerByteCount), maximumLoadCommandByteCount) else {
            throw FormatFailure.damaged("its header describes more data than the file holds")
        }
        guard commandCount <= 16_384, UInt64(commandCount) * 8 <= commandsByteCount else {
            throw FormatFailure.damaged("its header is too large to read")
        }

        let commands = try reader.read(at: offset + (is64 ? 32 : 28), count: Int(commandsByteCount))
        func word(_ at: Int) throws -> UInt32 { try commands.integer(at: at, bigEndian: bigEndian) }

        var cursor = 0
        for _ in 0 ..< commandCount {
            guard cursor + 8 <= commands.count else {
                throw FormatFailure.damaged("its load command list is truncated")
            }
            let command = try word(cursor)
            let size = Int(try word(cursor + 4))
            guard size >= 8, size % (is64 ? 8 : 4) == 0, size <= commands.count - cursor else {
                throw FormatFailure.damaged("part of its header is the wrong size")
            }

            switch command {
            case LoadCommand.uuid:
                guard size >= 24 else { break }
                let bytes = commands.subdata(in: cursor + 8 ..< cursor + 24)
                slice.uuid = UUID(uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
                ))

            case LoadCommand.loadDylib, LoadCommand.loadWeakDylib,
                 LoadCommand.reexportDylib, LoadCommand.loadUpwardDylib:
                if let name = try dylibName(commands, at: cursor, size: size, word: word) {
                    slice.linkedLibraries.append(name)
                }

            case LoadCommand.identifyDylib:
                slice.installName = try dylibName(commands, at: cursor, size: size, word: word)

            case LoadCommand.encryptionInfo, LoadCommand.encryptionInfo64:
                guard size >= 20 else { break }
                slice.isEncrypted = try word(cursor + 16) != 0

            case LoadCommand.codeSignature:
                guard size >= 16 else { break }
                let dataOffset = Int64(try word(cursor + 8))
                let dataByteCount = Int64(try word(cursor + 12))
                slice.isCodeSigned = true
                if dataByteCount > 0, dataOffset + dataByteCount <= byteCount {
                    slice.signature = SignatureLocation(offset: offset + dataOffset, byteCount: dataByteCount)
                }

            default:
                break
            }
            cursor += size
        }
        guard cursor == commands.count else { throw FormatFailure.damaged("its load commands do not match the header") }
        return slice
    }

    /// A `dylib_command` stores its name as an offset from the start of the
    /// command, so a hostile one can point anywhere; the string is clamped to
    /// the command it belongs to.
    private static func dylibName(
        _ commands: Data,
        at cursor: Int,
        size: Int,
        word: (Int) throws -> UInt32
    ) throws -> String? {
        guard size >= 24 else { return nil }
        let nameOffset = Int(try word(cursor + 8))
        guard nameOffset >= 12, nameOffset < size else { return nil }
        return try commands.string(at: cursor + nameOffset, count: size - nameOffset)
    }

    /// Load commands are a handful of kilobytes in anything sane; a header
    /// claiming more than this is trying to make us allocate.
    private static let maximumLoadCommandByteCount: Int64 = 16 * 1024 * 1024

    private static let embeddedSignatureMagic: UInt32 = 0xFADE_0CC0
    private static let entitlementsMagic: UInt32 = 0xFADE_7171

    private enum LoadCommand {
        static let identifyDylib: UInt32 = 0x0D
        static let loadDylib: UInt32 = 0x0C
        static let uuid: UInt32 = 0x1B
        static let codeSignature: UInt32 = 0x1D
        static let encryptionInfo: UInt32 = 0x21
        static let encryptionInfo64: UInt32 = 0x2C
        /// The high bit is `LC_REQ_DYLD`: dyld must understand these or refuse
        /// to load the image, and it is part of the value on disk.
        static let loadWeakDylib: UInt32 = 0x8000_0018
        static let reexportDylib: UInt32 = 0x8000_001F
        static let loadUpwardDylib: UInt32 = 0x8000_0023
    }
}

/// The name `lipo` prints, from the `cpu_type_t` / `cpu_subtype_t` pair.
///
/// `NXGetArchInfoFromCpuType` would do this and does not exist on iOS, so the
/// table is here. Only the architectures Apple still ships are named; anything
/// else reads back as its numbers, which is more useful in a properties screen
/// than "unknown".
func architectureName(cpuType: Int32, cpuSubtype: Int32) -> String {
    // The top byte of a subtype is capability bits, not identity.
    let subtype = cpuSubtype & 0x00FF_FFFF
    switch (cpuType, subtype) {
    case (0x0100_000C, 0): return "arm64"
    case (0x0100_000C, 1): return "arm64v8"
    case (0x0100_000C, 2): return "arm64e"
    case (0x0200_000C, 1): return "arm64_32"
    case (0x0000_000C, 6): return "armv6"
    case (0x0000_000C, 9): return "armv7"
    case (0x0000_000C, 11): return "armv7s"
    case (0x0000_000C, 12): return "armv7k"
    case (0x0100_0007, 3): return "x86_64"
    case (0x0100_0007, 8): return "x86_64h"
    case (0x0000_0007, _): return "i386"
    case (0x0000_000C, _): return "arm"
    case (0x0100_000C, _): return "arm64"
    default: return "cputype \(cpuType) subtype \(subtype)"
    }
}
