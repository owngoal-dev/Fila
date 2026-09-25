import Foundation

extension Create.Request: CustomDebugStringConvertible {
    public var debugDescription: String {
        """
        \(header)
        Create Request (\(String(format: "0x%02x", header.command)))
          StructureSize: \(structureSize)
          Security Flags: \(securityFlags)
          Oplock: \(Create.OplockLevel.debugDescription(rawValue: requestedOplockLevel))
          Impersonation level: \(Create.ImpersonationLevel.debugDescription(rawValue: impersonationLevel))
          Create Flags: \(String(format: "0x%016x", smbCreateFlags))
          Reserved: \(String(format: "0x%016x", reserved))
          Access Mask: \(desiredAccess)
          File Attributes: \(fileAttributes)
          Share Access: \(shareAccess)
          Disposition: \(Create.CreateDisposition.debugDescription(rawValue: createDisposition))
          Create Options: \(createOptions)
          Blob Offset: \(nameOffset)
          Blob Length: \(nameLength)
          Create Contexts Offset: \(createContextsOffset)
          Create Contexts Length: \(createContextsLength)
          Filename: \(String(data: buffer, encoding: .utf16LittleEndian) ?? buffer.hex)
        """
    }
}

extension Create.Response: CustomDebugStringConvertible {
    public var debugDescription: String {
        """
        \(header)
        Create Response (\(String(format: "0x%02x", header.command)))
          StructureSize: \(structureSize)
          Oplock: \(Create.OplockLevel.debugDescription(rawValue: oplockLevel))
          Response Flags: \(flags)
          Create Action: \(Create.CreateAction.debugDescription(rawValue: createAction))
          Create: \(FileTime(creationTime))
          Last Access: \(FileTime(lastAccessTime))
          Last Write: \(FileTime(lastWriteTime))
          Last Change: \(FileTime(changeTime))
          Allocation Size: \(allocationSize)
          End Of File: \(endOfFile)
          File Attributes: \(fileAttributes)
          Reserved: \(String(format: "%04x", reserved2))
          GUID handle File: \(fileId.to(type: UUID.self))
          Blob Offset: \(createContextsOffset)
          Blob Length: \(createContextsLength)
          ExtraInfo: \(buffer.hex)
        """
    }
}

extension Create.OplockLevel: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .none:
            "No oplock"
        case .ii:
            "Level2 oplock"
        case .exclusive:
            "Exclusive oplock"
        case .batch:
            "Batch oplock"
        case .lease:
            "Lease"
        }
    }

    public static func debugDescription(rawValue: UInt8) -> String {
        if let oplockLevel = Create.OplockLevel(rawValue: rawValue) {
            oplockLevel.debugDescription
        } else {
            String(format: "0x%02x", rawValue)
        }
    }
}

extension Create.ImpersonationLevel: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .anonymous:
            "Anonymous"
        case .identification:
            "Identification"
        case .impersonation:
            "Impersonation"
        case .delegation:
            "Delegation"
        }
    }

    public static func debugDescription(rawValue: UInt32) -> String {
        if let impersonationLevel = Create.ImpersonationLevel(rawValue: rawValue) {
            impersonationLevel.debugDescription
        } else {
            String(format: "0x%08x", rawValue)
        }
    }
}

extension Create.ShareAccess: CustomDebugStringConvertible {
    public var debugDescription: String {
        var values = [String]()
        if contains(.read) {
            values.append("Read")
        }
        if contains(.write) {
            values.append("Write")
        }
        if contains(.delete) {
            values.append("Delete")
        }

        if values.isEmpty {
            return "\(String(format: "0x%08x", rawValue))"
        } else {
            return "\(String(format: "0x%08x", rawValue)) (\(values.joined(separator: ", ")))"
        }
    }
}

extension Create.CreateDisposition: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .supersede:
            "Supersede (supersede existing file (if it exists))"
        case .open:
            "Open (if file exists open it, else fail)"
        case .create:
            "Create (if file exists fail, else create it)"
        case .openIf:
            "Open If (if file exists open it, else create it)"
        case .overwrite:
            "Overwrite (if file exists overwrite, else fail)"
        case .overwriteIf:
            "Overwrite If (if file exists overwrite, else create it)"
        }
    }

    public static func debugDescription(rawValue: UInt32) -> String {
        if let disposition = Create.CreateDisposition(rawValue: rawValue) {
            disposition.debugDescription
        } else {
            String(format: "0x%08x", rawValue)
        }
    }
}

extension Create.CreateOptions: CustomDebugStringConvertible {
    public var debugDescription: String {
        var values = [String]()

        if contains(.directoryFile) {
            values.append("Directory")
        }
        if contains(.writeThrough) {
            values.append("Write Through")
        }
        if contains(.sequentialOnly) {
            values.append("Sequential Only")
        }
        if contains(.noIntermediateBuffering) {
            values.append("Intermediate Buffering")
        }
        if contains(.synchronousIoAlert) {
            values.append("Sync I/O Alert")
        }
        if contains(.synchronousIoNonAlert) {
            values.append("Sync I/O Nonalert")
        }
        if contains(.nonDirectoryFile) {
            values.append("Non-Directory")
        }
        if contains(.completeIfOplocked) {
            values.append("Complete If Oplocked")
        }
        if contains(.noEaKnowledge) {
            values.append("No EA Knowledge")
        }
        if contains(.randomAccess) {
            values.append("Random Access")
        }
        if contains(.deleteOnClose) {
            values.append("Delete On Close")
        }
        if contains(.openByFileId) {
            values.append("Open By FileID")
        }
        if contains(.openForBackupIntent) {
            values.append("Backup Intent")
        }
        if contains(.noCompression) {
            values.append("No Compression")
        }
        if contains(.openRemoteInstance) {
            values.append("Open Remote Instance")
        }
        if contains(.requiringOplock) {
            values.append("Requiring Oplock")
        }
        if contains(.disallowExclusive) {
            values.append("Disallow Exclusive")
        }
        if contains(.reserveOpfilter) {
            values.append("Reserve Opfilter")
        }
        if contains(.openReparsePoint) {
            values.append("Open Reparse Point")
        }
        if contains(.openNoRecall) {
            values.append("Open No Recall")
        }
        if contains(.openForFreeSpaceQuery) {
            values.append("Open For Free Space Query")
        }

        if values.isEmpty {
            return "\(String(format: "0x%08x", rawValue))"
        } else {
            return "\(String(format: "0x%08x", rawValue)) (\(values.joined(separator: ", ")))"
        }
    }
}

extension Create.Flags: CustomDebugStringConvertible {
    public var debugDescription: String {
        var values = [String]()
        if contains(.releasePoint) {
            values.append("Release Point")
        }

        if values.isEmpty {
            return "\(String(format: "0x%02x", rawValue))"
        } else {
            return "\(String(format: "0x%02x", rawValue)) (\(values.joined(separator: ", ")))"
        }
    }
}

extension Create.CreateAction: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .superseded:
            "No action taken?"
        case .opened:
            "The file existed and was opened"
        case .created:
            "The file did not exist but was created"
        case .overwritten:
            "The file existed and was truncated"
        }
    }

    public static func debugDescription(rawValue: UInt32) -> String {
        if let action = Create.CreateAction(rawValue: rawValue) {
            action.debugDescription
        } else {
            String(format: "0x%08x", rawValue)
        }
    }
}
