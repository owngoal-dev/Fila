import Foundation

extension Header: CustomDebugStringConvertible {
    public var debugDescription: String {
        if flags.contains(.serverToRedir) {
            """
            SMB2 Header
              ProtocolId: \(String(format: "0x%08x", protocolId.bigEndian))
              Header Length: \(structureSize)
              Credit Charge: \(creditCharge)
              NT Status: \(NTStatus(status).debugDescription) (\(String(format: "0x%08x", status)))
              Command: \(Command.debugDescription(rawValue: command)) (\(command))
              Credits granted: \(creditRequestResponse)
              Flags: \(flags)
              Chain Offset: \(nextCommand)
              Message ID: \(messageId)
              Process Id: \(String(format: "0x%08x", reserved))
              Tree Id: \(String(format: "0x%08x", treeId))
              Session Id: \(String(format: "0x%016llx", sessionId))
              Signature: \(signature.hex)
            """
        } else {
            """
            SMB2 Header
              ProtocolId: \(String(format: "0x%08x", protocolId.bigEndian))
              Header Length: \(structureSize)
              Credit Charge: \(creditCharge)
              Channel Sequence: \(String((status & 0xFFFF_0000) >> 16, radix: 16))
              Reserved: \(String(format: "%04x", status & 0x0000_FFFF))
              Command: \(Command.debugDescription(rawValue: command)) (\(command))
              Credits requested: \(creditRequestResponse)
              Flags: \(flags)
              Chain Offset: \(nextCommand)
              Message ID: \(messageId)
              Process Id: \(String(format: "0x%08x", reserved))
              Tree Id: \(String(format: "0x%08x", treeId))
              Session Id: \(String(format: "0x%016llx", sessionId))
              Signature: \(signature.hex)
            """
        }
    }
}

extension Header.Command: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .negotiate: "Negotiate Protocol"
        case .sessionSetup: "SESSION_SETUP"
        case .logoff: "LOGOFF"
        case .treeConnect: "TREE_CONNECT"
        case .treeDisconnect: "TREE_DISCONNECT"
        case .create: "CREATE"
        case .close: "CLOSE"
        case .flush: "FLUSH"
        case .read: "READ"
        case .write: "WRITE"
        case .lock: "LOCK"
        case .ioctl: "IOCTL"
        case .cancel: "CANCEL"
        case .echo: "ECHO"
        case .queryDirectory: "QUERY_DIRECTORY"
        case .changeNotify: "CHANGE_NOTIFY"
        case .queryInfo: "QUERY_INFO"
        case .setInfo: "SET_INFO"
        case .oplockBreak: "OPLOCK_BREAK"
        case .serverToClientNotification: "SERVER_TO_CLIENT_NOTIFICATION"
        }
    }

    public static func debugDescription(rawValue: UInt16) -> String {
        if let command = Header.Command(rawValue: rawValue) {
            command.debugDescription
        } else {
            String(format: "0x%04x", rawValue)
        }
    }
}

extension Header.Flags: CustomDebugStringConvertible {
    public var debugDescription: String {
        var values = [String]()

        if contains(.serverToRedir) {
            values.append("Response")
        }
        if contains(.asyncCommand) {
            values.append("Async command")
        }
        if contains(.relatedOperations) {
            values.append("Chained")
        }
        if contains(.signed) {
            values.append("Signing")
        }
        if contains(.priorityMask) {
            values.append("Priority")
        }
        if contains(.dfsOperation) {
            values.append("DFS operation")
        }
        if contains(.replayOperation) {
            values.append("Replay operation")
        }

        if values.isEmpty {
            return String(format: "0x%08x", rawValue)
        } else {
            return "\(String(format: "0x%08x", rawValue)) (\(values.joined(separator: ", ")))"
        }
    }
}
