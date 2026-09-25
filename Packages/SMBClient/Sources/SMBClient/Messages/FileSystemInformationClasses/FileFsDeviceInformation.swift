import Foundation

public struct FileFsDeviceInformation {
    public let deviceType: UInt32
    public let characteristics: Characteristics

    public enum DeviceType: UInt32 {
        case cdRom = 0x0000_0002
        case disk = 0x0000_0007
    }

    public struct Characteristics: OptionSet {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let removableMedia = Characteristics(rawValue: 0x0000_0001)
        public static let readOnlyDevice = Characteristics(rawValue: 0x0000_0002)
        public static let floppyDiskette = Characteristics(rawValue: 0x0000_0004)
        public static let writeOnceMedia = Characteristics(rawValue: 0x0000_0008)
        public static let remoteDevice = Characteristics(rawValue: 0x0000_0010)
        public static let deviceIsMounted = Characteristics(rawValue: 0x0000_0020)
        public static let virtualVolume = Characteristics(rawValue: 0x0000_0040)
        public static let deviceSecureOpen = Characteristics(rawValue: 0x0000_0100)
        public static let characteristicTsDevice = Characteristics(rawValue: 0x0000_1000)
        public static let characteristicWebDavDevice = Characteristics(rawValue: 0x0000_2000)
        public static let deviceAllowAppContainerTraversal = Characteristics(rawValue: 0x0002_0000)
        public static let portableDevice = Characteristics(rawValue: 0x0000_4000)
    }

    public init(data: Data) {
        let reader = ByteReader(data)

        deviceType = reader.read()
        characteristics = Characteristics(rawValue: reader.read())
    }
}
