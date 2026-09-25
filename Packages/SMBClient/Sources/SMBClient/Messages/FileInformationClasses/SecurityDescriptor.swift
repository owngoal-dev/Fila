import Foundation

public struct SecurityDescriptor: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let owner = SecurityDescriptor(rawValue: 0x0000_0001)
    public static let group = SecurityDescriptor(rawValue: 0x0000_0002)
    public static let dacl = SecurityDescriptor(rawValue: 0x0000_0004)
    public static let sacl = SecurityDescriptor(rawValue: 0x0000_0008)
    public static let label = SecurityDescriptor(rawValue: 0x0000_0010)
    public static let attribute = SecurityDescriptor(rawValue: 0x0000_0020)
    public static let scope = SecurityDescriptor(rawValue: 0x0000_0040)
    public static let backup = SecurityDescriptor(rawValue: 0x0000_0080)
}
