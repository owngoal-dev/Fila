import Foundation

public struct DirectoryAccessMask: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let listDirectory = DirectoryAccessMask(rawValue: 0x0000_0001)
    public static let addFile = DirectoryAccessMask(rawValue: 0x0000_0002)
    public static let addSubdirectory = DirectoryAccessMask(rawValue: 0x0000_0004)
    public static let readEa = DirectoryAccessMask(rawValue: 0x0000_0008)
    public static let writeEa = DirectoryAccessMask(rawValue: 0x0000_0010)
    public static let traverse = DirectoryAccessMask(rawValue: 0x0000_0020)
    public static let deleteChild = DirectoryAccessMask(rawValue: 0x0000_0040)
    public static let readAttributes = DirectoryAccessMask(rawValue: 0x0000_0080)
    public static let writeAttributes = DirectoryAccessMask(rawValue: 0x0000_0100)
    public static let delete = DirectoryAccessMask(rawValue: 0x0001_0000)
    public static let readControl = DirectoryAccessMask(rawValue: 0x0002_0000)
    public static let writeDac = DirectoryAccessMask(rawValue: 0x0004_0000)
    public static let writeOwner = DirectoryAccessMask(rawValue: 0x0008_0000)
    public static let synchronize = DirectoryAccessMask(rawValue: 0x0010_0000)
    public static let accessSystemSecurity = DirectoryAccessMask(rawValue: 0x0100_0000)
    public static let maximumAllowed = DirectoryAccessMask(rawValue: 0x0200_0000)
    public static let genericAll = DirectoryAccessMask(rawValue: 0x1000_0000)
    public static let genericExecute = DirectoryAccessMask(rawValue: 0x2000_0000)
    public static let genericWrite = DirectoryAccessMask(rawValue: 0x4000_0000)
    public static let genericRead = DirectoryAccessMask(rawValue: 0x8000_0000)
}
