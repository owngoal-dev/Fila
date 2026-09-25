import Foundation

public struct AccessMask: OptionSet {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let readEa = DirectoryAccessMask(rawValue: 0x0000_0008)
    public static let writeEa = DirectoryAccessMask(rawValue: 0x0000_0010)

    public static let readAttributes = FilePipePrinterAccessMask(rawValue: 0x0000_0080)
    public static let writeAttributes = FilePipePrinterAccessMask(rawValue: 0x0000_0100)
    public static let delete = FilePipePrinterAccessMask(rawValue: 0x0001_0000)
    public static let readControl = FilePipePrinterAccessMask(rawValue: 0x0002_0000)
    public static let writeDac = FilePipePrinterAccessMask(rawValue: 0x0004_0000)
    public static let writeOwner = FilePipePrinterAccessMask(rawValue: 0x0008_0000)
    public static let synchronize = FilePipePrinterAccessMask(rawValue: 0x0010_0000)
    public static let accessSystemSecurity = FilePipePrinterAccessMask(rawValue: 0x0100_0000)
    public static let maximumAllowed = FilePipePrinterAccessMask(rawValue: 0x0200_0000)
    public static let genericAll = FilePipePrinterAccessMask(rawValue: 0x1000_0000)
    public static let genericExecute = FilePipePrinterAccessMask(rawValue: 0x2000_0000)
    public static let genericWrite = FilePipePrinterAccessMask(rawValue: 0x4000_0000)
    public static let genericRead = FilePipePrinterAccessMask(rawValue: 0x8000_0000)

    public static let listDirectory = DirectoryAccessMask(rawValue: 0x0000_0001)
    public static let addFile = DirectoryAccessMask(rawValue: 0x0000_0002)
    public static let addSubdirectory = DirectoryAccessMask(rawValue: 0x0000_0004)
    public static let traverse = DirectoryAccessMask(rawValue: 0x0000_0020)

    public static let readData = FilePipePrinterAccessMask(rawValue: 0x0000_0001)
    public static let writeData = FilePipePrinterAccessMask(rawValue: 0x0000_0002)
    public static let appendData = FilePipePrinterAccessMask(rawValue: 0x0000_0004)
    public static let execute = FilePipePrinterAccessMask(rawValue: 0x0000_0020)
}
