import Foundation

public struct FileAlignmentInformation {
    public let alignmentRequirement: AlignmentRequirement

    public struct AlignmentRequirement: OptionSet, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let byte = AlignmentRequirement([]) // 0x00000000
        public static let word = AlignmentRequirement(rawValue: 0x0000_0001)
        public static let long = AlignmentRequirement(rawValue: 0x0000_0003)
        public static let quad = AlignmentRequirement(rawValue: 0x0000_0007)
        public static let octa = AlignmentRequirement(rawValue: 0x0000_000F)
        public static let thirtyTwo = AlignmentRequirement(rawValue: 0x0000_001F)
        public static let sixtyFour = AlignmentRequirement(rawValue: 0x0000_003F)
        public static let oneTwentyEight = AlignmentRequirement(rawValue: 0x0000_007F)
        public static let twoFiftySix = AlignmentRequirement(rawValue: 0x0000_00FF)
        public static let fiveTwelve = AlignmentRequirement(rawValue: 0x0000_01FF)
    }

    public init(data: Data) {
        let reader = ByteReader(data)
        alignmentRequirement = AlignmentRequirement(rawValue: reader.read())
    }
}

extension ByteReader {
    func read() -> FileAlignmentInformation {
        FileAlignmentInformation(data: read(count: 4))
    }
}
