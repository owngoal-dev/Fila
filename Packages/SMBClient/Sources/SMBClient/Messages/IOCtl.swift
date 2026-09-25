import Foundation

public enum IOCtl {
    public struct Request: Message.Request {
        public typealias Response = IOCtl.Response

        public let header: Header
        public let structureSize: UInt16
        public let reserved: UInt16
        public let ctlCode: UInt32
        public let fileId: Data
        public let inputOffset: UInt32
        public let inputCount: UInt32
        public let maxInputResponse: UInt32
        public let outputOffset: UInt32
        public let outputCount: UInt32
        public let maxOutputResponse: UInt32
        public let flags: Flags
        public let reserved2: UInt32
        public let buffer: Data

        public init(
            headerFlags: Header.Flags = [],
            creditCharge: UInt16,
            messageId: UInt64,
            treeId: UInt32,
            sessionId: UInt64,
            ctlCode: CtlCode,
            fileId: Data,
            input: Data,
            output: Data,
        ) {
            header = Header(
                creditCharge: creditCharge,
                command: .ioctl,
                creditRequest: 256,
                flags: headerFlags,
                messageId: messageId,
                treeId: treeId,
                sessionId: sessionId,
            )

            structureSize = 57
            reserved = 0
            self.ctlCode = ctlCode.rawValue
            self.fileId = fileId
            inputOffset = 120
            inputCount = UInt32(truncatingIfNeeded: input.count)
            maxInputResponse = 0
            outputOffset = 0
            outputCount = 0
            maxOutputResponse = 65536
            flags = [.isFsctl]
            reserved2 = 0
            buffer = input + output
        }

        public func encoded() -> Data {
            var data = Data()

            data += header.encoded()
            data += structureSize
            data += reserved
            data += ctlCode
            data += fileId
            data += inputOffset
            data += inputCount
            data += maxInputResponse
            data += outputOffset
            data += outputCount
            data += maxOutputResponse
            data += flags.rawValue
            data += reserved2
            data += buffer

            return data
        }
    }

    public struct Response: Message.Response {
        public let header: Header
        public let structureSize: UInt16
        public let reserved: UInt16
        public let ctlCode: UInt32
        public let fileId: Data
        public let inputOffset: UInt32
        public let inputCount: UInt32
        public let outputOffset: UInt32
        public let outputCount: UInt32
        public let flags: Flags
        public let reserved2: UInt32
        public let buffer: Data

        public init(data: Data) {
            let reader = ByteReader(data)

            header = reader.read()

            structureSize = reader.read()
            reserved = reader.read()
            ctlCode = reader.read()
            fileId = reader.read(count: 16)
            inputOffset = reader.read()
            inputCount = reader.read()
            outputOffset = reader.read()
            outputCount = reader.read()
            flags = Flags(rawValue: reader.read())
            reserved2 = reader.read()
            buffer = reader.read(count: Int(outputCount))
        }
    }

    public enum CtlCode: UInt32 {
        case dfsGetReferrals = 0x0006_0194
        case pipePeek = 0x0011_400C
        case pipeWait = 0x0011_0018
        case pipeTransceive = 0x0011_C017
        case srvCopyChunk = 0x0014_40F2
        case srvEnumerateSnapshots = 0x0014_4064
        case srvRequestResumeKey = 0x0014_0078
        case srvReadHash = 0x0014_41BB
        case srvCopyChunkWrite = 0x0014_80F2
        case lmrRequestResiliency = 0x0014_01D4
        case queryNetworkInterfaceInfo = 0x0014_01FC
        case setReleasePoint = 0x0009_00A4
        case dfsGetReferralsEx = 0x0006_01B0
        case fileLevelTrim = 0x0009_8208
        case validateNegotiateInfo = 0x0014_0204
    }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let isIoctl = Flags([]) // 0x00000000
        public static let isFsctl = Flags(rawValue: 0x0000_0001)
    }
}
