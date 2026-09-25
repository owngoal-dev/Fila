import Foundation

public struct NTStatus {
    public var rawValue: UInt32

    public init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

extension NTStatus: CustomStringConvertible {
    public var description: String {
        switch ErrorCode(rawValue: rawValue) {
        case .success:
            "The client request is successful."
        case .pending:
            "The operation that was requested is pending completion."
        case .invalidSMB:
            "The server rejected this request. Try again."
        case .smbBadTid:
            "The connection to this share is no longer valid. Reconnect and try again."
        case .smbBadCommand:
            "The server does not support this operation."
        case .smbBadUID:
            "This session is no longer valid. Sign in again."
        case .smbUseStandard:
            "The server does not support this operation."
        case .bufferOverflow:
            "The data is too large. Try a smaller item."
        case .noMoreFiles:
            "No more matching files were found."
        case .stoppedOnSymlink:
            "This path is a link. Open the item it points to instead."
        case .notImplemented:
            "The server does not support this operation."
        case .invalidInfoClass:
            "The server does not support this request."
        case .invalidParameter:
            "That value is not valid. Check it and try again."
        case .noSuchFile:
            "That file was not found. Refresh the folder, or choose another item."
        case .noSuchDevice:
            "That location does not exist on this server."
        case .invalidDeviceRequest:
            "This operation cannot be used with this item. Choose a different item."
        case .endOfFile:
            "The end of the file was reached."
        case .moreProcessingRequired:
            "The server needs more information to sign in. Try again."
        case .accessDenied:
            "The account is not allowed to do that."
        case .bufferTooSmall:
            "The data is too large. Try a smaller item."
        case .objectNameInvalid:
            "That name is not valid on this server. Choose another name."
        case .objectNameNotFound:
            "That item was not found."
        case .objectNameCollision:
            "An item with that name already exists. Choose a different name."
        case .sharingViolation:
            "This file is in use on the server. Close it there and try again."
        case .deletePending:
            "This item is already being deleted on the server. Wait and try again."
        case .objectPathNotFound:
            "That folder was not found."
        case .logonFailure:
            "The server refused the account name or password."
        case .badImpersonationLevel:
            "The server refused this request. Try again."
        case .ioTimeout:
            "The server did not respond in time. Try again."
        case .fileIsADirectory:
            "That name is a folder, not a file."
        case .notSupported:
            "The server does not support this operation."
        case .networkNameDeleted:
            "This share is no longer available. Reconnect and try again."
        case .badNetworkName:
            "This share is not on the server. Choose another share."
        case .directoryNotEmpty:
            "The folder on the server is not empty. Remove its contents first."
        case .notADirectory:
            "That name is a file, not a folder."
        case .fileClosed:
            "This file is no longer open. Try again."
        case .userSessionDeleted:
            "This session is no longer valid. Sign in again."
        case .connectionRefused:
            "The server refused the connection. Check the address and try again."
        case .networkSessionExpired:
            "The session expired. Sign in again."
        case .fileSystemLimitation:
            "The server cannot finish this because of a limit. Try a smaller item or another location."
        case .smbTooManyUIDs:
            "Too many sessions are open on this server. Disconnect one and try again."
        default:
            "The server refused this request. Try again."
        }
    }
}

extension NTStatus: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch ErrorCode(rawValue: rawValue) {
        case .success:
            "SUCCESS"
        case .pending:
            "PENDING"
        case .invalidSMB:
            "INVALID_SMB"
        case .smbBadTid:
            "SMB_BAD_TID"
        case .smbBadCommand:
            "SMB_BAD_COMMAND"
        case .smbBadUID:
            "SMB_BAD_UID"
        case .smbUseStandard:
            "SMB_USE_STANDARD"
        case .bufferOverflow:
            "BUFFER_OVERFLOW"
        case .noMoreFiles:
            "NO_MORE_FILES"
        case .stoppedOnSymlink:
            "STOPPED_ON_SYMLINK"
        case .notImplemented:
            "NOT_IMPLEMENTED"
        case .invalidInfoClass:
            "INVALID_INFO_CLASS"
        case .invalidParameter:
            "INVALID_PARAMETER"
        case .noSuchDevice:
            "NO_SUCH_DEVICE"
        case .noSuchFile:
            "NO_SUCH_FILE"
        case .invalidDeviceRequest:
            "INVALID_DEVICE_REQUEST"
        case .endOfFile:
            "END_OF_FILE"
        case .moreProcessingRequired:
            "MORE_PROCESSING_REQUIRED"
        case .accessDenied:
            "ACCESS_DENIED"
        case .bufferTooSmall:
            "BUFFER_TOO_SMALL"
        case .objectNameInvalid:
            "OBJECT_NAME_INVALID"
        case .objectNameNotFound:
            "OBJECT_NAME_NOT_FOUND"
        case .objectNameCollision:
            "OBJECT_NAME_COLLISION"
        case .sharingViolation:
            "SHARING_VIOLATION"
        case .deletePending:
            "DELETE_PENDING"
        case .objectPathNotFound:
            "OBJECT_PATH_NOT_FOUND"
        case .logonFailure:
            "LOGON_FAILURE"
        case .badImpersonationLevel:
            "BAD_IMPERSONATION_LEVEL"
        case .ioTimeout:
            "IO_TIMEOUT"
        case .fileIsADirectory:
            "FILE_IS_A_DIRECTORY"
        case .notSupported:
            "NOT_SUPPORTED"
        case .networkNameDeleted:
            "NETWORK_NAME_DELETED"
        case .badNetworkName:
            "BAD_NETWORK_NAME"
        case .directoryNotEmpty:
            "DIRECTORY_NOT_EMPTY"
        case .notADirectory:
            "NOT_A_DIRECTORY"
        case .fileClosed:
            "FILE_CLOSED"
        case .userSessionDeleted:
            "USER_SESSION_DELETED"
        case .connectionRefused:
            "CONNECTION_REFUSED"
        case .networkSessionExpired:
            "NETWORK_SESSION_EXPIRED"
        case .fileSystemLimitation:
            "FILE_SYSTEM_LIMITATION"
        case .smbTooManyUIDs:
            "SMB_TOO_MANY_UIDS"
        default:
            "UNKNOWN_ERROR"
        }
    }
}

public enum ErrorCode: UInt32 {
    case success = 0x0000_0000
    case pending = 0x0000_0103
    case invalidSMB = 0x0001_0002
    case smbBadTid = 0x0005_0002
    case smbBadCommand = 0x0016_0002
    case smbBadUID = 0x005B_0002
    case smbUseStandard = 0x00FB_0002
    case bufferOverflow = 0x8000_0005
    case noMoreFiles = 0x8000_0006
    case stoppedOnSymlink = 0x8000_002D
    case notImplemented = 0xC000_0002
    case invalidInfoClass = 0xC000_0003
    case invalidParameter = 0xC000_000D
    case noSuchDevice = 0xC000_000E
    case noSuchFile = 0xC000_000F
    case invalidDeviceRequest = 0xC000_0010
    case endOfFile = 0xC000_0011
    case moreProcessingRequired = 0xC000_0016
    case accessDenied = 0xC000_0022
    case bufferTooSmall = 0xC000_0023
    case objectNameInvalid = 0xC000_0033
    case objectNameNotFound = 0xC000_0034
    case objectNameCollision = 0xC000_0035
    case sharingViolation = 0xC000_0043
    case deletePending = 0xC000_0056
    case objectPathNotFound = 0xC000_003A
    case logonFailure = 0xC000_006D
    case badImpersonationLevel = 0xC000_00A5
    case ioTimeout = 0xC000_00B5
    case fileIsADirectory = 0xC000_00BA
    case notSupported = 0xC000_00BB
    case networkNameDeleted = 0xC000_00C9
    case badNetworkName = 0xC000_00CC
    case directoryNotEmpty = 0xC000_0101
    case notADirectory = 0xC000_0103
    case fileClosed = 0xC000_0128
    case userSessionDeleted = 0xC000_0203
    case connectionRefused = 0xC000_0236
    case networkSessionExpired = 0xC000_035C
    case fileSystemLimitation = 0xC000_0427
    case smbTooManyUIDs = 0xC000_205A
}

public func == (lhs: NTStatus, rhs: ErrorCode) -> Bool {
    lhs.rawValue == rhs.rawValue
}

public func == (lhs: ErrorCode, rhs: NTStatus) -> Bool {
    lhs.rawValue == rhs.rawValue
}

public func != (lhs: NTStatus, rhs: ErrorCode) -> Bool {
    lhs.rawValue != rhs.rawValue
}

public func != (lhs: ErrorCode, rhs: NTStatus) -> Bool {
    lhs.rawValue != rhs.rawValue
}

public func ~= (pattern: ErrorCode, value: NTStatus) -> Bool {
    pattern.rawValue == value.rawValue
}
