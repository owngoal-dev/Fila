import Foundation

public struct ErrorResponse: Error {
    public let header: Header
    public let structureSize: UInt16
    public let errorContextCount: UInt8
    public let reserved: UInt8

    public init(data: Data) {
        let reader = ByteReader(data)

        header = reader.read()
        structureSize = reader.read()
        errorContextCount = reader.read()
        reserved = reader.read()
    }
}

extension ErrorResponse: CustomStringConvertible {
    public var description: String {
        NTStatus(header.status).description
    }
}

extension ErrorResponse: LocalizedError {
    public var errorDescription: String? {
        switch NTStatus(header.status) {
        case .success:
            "Success"
        case .pending:
            "Pending"
        case .invalidSMB:
            "Invalid SMB"
        case .smbBadTid:
            "Bad TID"
        case .smbBadCommand:
            "Bad Command"
        case .smbBadUID:
            "Bad UID"
        case .smbUseStandard:
            "Use Standard"
        case .bufferOverflow:
            "Buffer Overflow"
        case .noMoreFiles:
            "No More Files"
        case .stoppedOnSymlink:
            "Stopped on Symlink"
        case .notImplemented:
            "Not Implemented"
        case .invalidInfoClass:
            "Invalid Info Class"
        case .invalidParameter:
            "Invalid Parameter"
        case .noSuchDevice:
            "No Such Device"
        case .noSuchFile:
            "No Such File"
        case .invalidDeviceRequest:
            "Invalid Device Request"
        case .endOfFile:
            "End of File"
        case .moreProcessingRequired:
            "More Processing Required"
        case .accessDenied:
            "Access Denied"
        case .bufferTooSmall:
            "Buffer Too Small"
        case .objectNameInvalid:
            "Object Name Invalid"
        case .objectNameNotFound:
            "Object Name Not Found"
        case .objectNameCollision:
            "Object Name Collision"
        case .sharingViolation:
            "Sharing Violation"
        case .deletePending:
            "Delete Pending"
        case .objectPathNotFound:
            "Object Path Not Found"
        case .logonFailure:
            "Logon Failure"
        case .badImpersonationLevel:
            "Bad Impersonation Level"
        case .ioTimeout:
            "IO Timeout"
        case .fileIsADirectory:
            "File is a Directory"
        case .notSupported:
            "Not Supported"
        case .networkNameDeleted:
            "Network Name Deleted"
        case .badNetworkName:
            "Bad Network Name"
        case .notADirectory:
            "Not a Directory"
        case .fileClosed:
            "File Closed"
        case .userSessionDeleted:
            "User Session Deleted"
        case .connectionRefused:
            "Connection Refused"
        case .networkSessionExpired:
            "Network Session Expired"
        case .smbTooManyUIDs:
            "Too Many UIDs"
        default:
            "Unknown error"
        }
    }

    public var failureReason: String? {
        description
    }

    public var recoverySuggestion: String? {
        description
    }
}
