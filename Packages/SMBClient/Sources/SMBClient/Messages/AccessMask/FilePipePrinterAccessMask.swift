import Foundation

public struct FilePipePrinterAccessMask: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let readData = FilePipePrinterAccessMask(rawValue: 0x0000_0001)
    public static let writeData = FilePipePrinterAccessMask(rawValue: 0x0000_0002)
    public static let appendData = FilePipePrinterAccessMask(rawValue: 0x0000_0004)
    public static let readEa = FilePipePrinterAccessMask(rawValue: 0x0000_0008)
    public static let writeEa = FilePipePrinterAccessMask(rawValue: 0x0000_0010)
    public static let execute = FilePipePrinterAccessMask(rawValue: 0x0000_0020)
    public static let deleteChild = FilePipePrinterAccessMask(rawValue: 0x0000_0040)
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
}

extension FilePipePrinterAccessMask: CustomDebugStringConvertible {
    public var debugDescription: String {
        var values = [String]()

        if contains(.readData) {
            values.append("Read")
        }
        if contains(.writeData) {
            values.append("Write")
        }
        if contains(.appendData) {
            values.append("Append")
        }
        if contains(.readEa) {
            values.append("Read EA")
        }
        if contains(.writeEa) {
            values.append("Write EA")
        }
        if contains(.execute) {
            values.append("Execute")
        }
        if contains(.deleteChild) {
            values.append("Delete Child")
        }
        if contains(.readAttributes) {
            values.append("Read Attributes")
        }
        if contains(.writeAttributes) {
            values.append("Write Attributes")
        }
        if contains(.delete) {
            values.append("Delete")
        }
        if contains(.readControl) {
            values.append("Read Control")
        }
        if contains(.writeDac) {
            values.append("Write DAC")
        }
        if contains(.writeOwner) {
            values.append("Write Owner")
        }
        if contains(.synchronize) {
            values.append("Synchronize")
        }
        if contains(.accessSystemSecurity) {
            values.append("Access System Security")
        }
        if contains(.maximumAllowed) {
            values.append("Maximum Allowed")
        }
        if contains(.genericAll) {
            values.append("Generic All")
        }
        if contains(.genericExecute) {
            values.append("Generic Execute")
        }
        if contains(.genericWrite) {
            values.append("Generic Write")
        }
        if contains(.genericRead) {
            values.append("Generic Read")
        }

        return "\(String(format: "0x%08x", rawValue)) (\(values.joined(separator: ", ")))"
    }
}
