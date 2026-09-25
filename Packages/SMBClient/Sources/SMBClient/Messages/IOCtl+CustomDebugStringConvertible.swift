import Foundation

extension IOCtl.Request: CustomDebugStringConvertible {
    public var debugDescription: String {
        """
        \(header)
        Ioctl Request (\(String(format: "0x%02x", header.command)))
          StructureSize: \(structureSize)
          Reserved: \(String(format: "%04x", reserved))
          Function: \(IOCtl.CtlCode.debugDescription(rawValue: ctlCode)) (\(String(format: "0x%08x", ctlCode)))
          GUID handle File: \(fileId.to(type: UUID.self))
          Blob Offset: \(inputOffset)
          Blob Length: \(inputCount)
          Max Ioctl In Size: \(maxInputResponse)
          Blob Offset: \(outputOffset)
          Blob Length: \(outputCount)
          Max Ioctl Out Size: \(maxOutputResponse)
          Flags: \(flags)
          Reserved: \(String(format: "%08x", reserved))
          Buffer: \(buffer.hex)
        """
    }
}

extension IOCtl.Response: CustomDebugStringConvertible {
    public var debugDescription: String {
        """
        \(header)
        Ioctl Response (\(String(format: "0x%02x", header.command)))
          StructureSize: \(structureSize)
          Reserved: \(String(format: "%04x", reserved))
          Function: \(IOCtl.CtlCode.debugDescription(rawValue: ctlCode)) (\(String(format: "0x%08x", ctlCode)))
          GUID handle File: \(fileId.to(type: UUID.self))
          Blob Offset: \(inputOffset)
          Blob Length: \(inputCount)
          Blob Offset: \(outputOffset)
          Blob Length: \(outputCount)
          Flags: \(flags)
          Reserved: \(String(format: "%08x", reserved))
          Buffer: \(buffer.hex)
        """
    }
}

extension IOCtl.CtlCode: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .dfsGetReferrals:
            "FSCTL_DFS_GET_REFERRALS"
        case .pipePeek:
            "FSCTL_PIPE_PEEK"
        case .pipeWait:
            "FSCTL_PIPE_WAIT"
        case .pipeTransceive:
            "FSCTL_PIPE_TRANSCEIVE"
        case .srvCopyChunk:
            "FSCTL_SRV_COPYCHUNK"
        case .srvEnumerateSnapshots:
            "FSCTL_SRV_ENUMERATE_SNAPSHOTS"
        case .srvRequestResumeKey:
            "FSCTL_SRV_REQUEST_RESUME_KEY"
        case .srvReadHash:
            "FSCTL_SRV_READ_HASH"
        case .srvCopyChunkWrite:
            "FSCTL_SRV_COPYCHUNK_WRITE"
        case .lmrRequestResiliency:
            "FSCTL_LMR_REQUEST_RESILIENCY"
        case .queryNetworkInterfaceInfo:
            "FSCTL_QUERY_NETWORK_INTERFACE_INFO"
        case .setReleasePoint:
            "FSCTL_SET_REPARSE_POINT"
        case .dfsGetReferralsEx:
            "FSCTL_DFS_GET_REFERRALS_EX"
        case .fileLevelTrim:
            "FSCTL_FILE_LEVEL_TRIM"
        case .validateNegotiateInfo:
            "FSCTL_VALIDATE_NEGOTIATE_INFO"
        }
    }

    public static func debugDescription(rawValue: UInt32) -> String {
        if let ctlCode = IOCtl.CtlCode(rawValue: rawValue) {
            ctlCode.debugDescription
        } else {
            String(format: "0x%08x", rawValue)
        }
    }
}

extension IOCtl.Flags: CustomDebugStringConvertible {
    public var debugDescription: String {
        var values = [String]()

        if contains(.isFsctl) {
            values.append("Is FSCTL: True")
        }

        if values.isEmpty {
            return "0x\(String(format: "%08x", rawValue))"
        } else {
            return "0x\(String(format: "%08x", rawValue)) (\(values.joined(separator: ", ")))"
        }
    }
}
