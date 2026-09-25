import Foundation

public enum InfoType: UInt8 {
    case file = 0x01
    case fileSystem = 0x02
    case security = 0x03
    case quota = 0x04
}

extension InfoType: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .file:
            "FILE_INFO (\(String(format: "0x%02x", rawValue)))"
        case .fileSystem:
            "FS_INFO (\(String(format: "0x%02x", rawValue)))"
        case .security:
            "SEC_INFO (\(String(format: "0x%02x", rawValue)))"
        case .quota:
            "QUOTA_INFO (\(String(format: "0x%02x", rawValue)))"
        }
    }

    public static func debugDescription(rawValue: UInt8) -> String {
        if let infoType = InfoType(rawValue: rawValue) {
            infoType.debugDescription
        } else {
            String(format: "0x%02x", rawValue)
        }
    }
}
