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
      return "The client request is successful."
    case .pending:
      return "The operation that was requested is pending completion."
    case .invalidSMB:
      return "The server rejected this request. Try again."
    case .smbBadTid:
      return "The connection to this share is no longer valid. Reconnect and try again."
    case .smbBadCommand:
      return "The server does not support this operation."
    case .smbBadUID:
      return "This session is no longer valid. Sign in again."
    case .smbUseStandard:
      return "The server does not support this operation."
    case .bufferOverflow:
      return "The data is too large. Try a smaller item."
    case .noMoreFiles:
      return "No more matching files were found."
    case .stoppedOnSymlink:
      return "This path is a link. Open the item it points to instead."
    case .notImplemented:
      return "The server does not support this operation."
    case .invalidInfoClass:
      return "The server does not support this request."
    case .invalidParameter:
      return "That value is not valid. Check it and try again."
    case .noSuchFile:
      return "That file was not found. Refresh the folder, or choose another item."
    case .noSuchDevice:
      return "That location does not exist on this server."
    case .invalidDeviceRequest:
      return "This operation cannot be used with this item. Choose a different item."
    case .endOfFile:
      return "The end of the file was reached."
    case .moreProcessingRequired:
      return "The server needs more information to sign in. Try again."
    case .accessDenied:
      return "The account is not allowed to do that."
    case .bufferTooSmall:
      return "The data is too large. Try a smaller item."
    case .objectNameInvalid:
      return "That name is not valid on this server. Choose another name."
    case .objectNameNotFound:
      return "That item was not found."
    case .objectNameCollision:
      return "An item with that name already exists. Choose a different name."
    case .sharingViolation:
      return "This file is in use on the server. Close it there and try again."
    case .deletePending:
      return "This item is already being deleted on the server. Wait and try again."
    case .objectPathNotFound:
      return "That folder was not found."
    case .logonFailure:
      return "The server refused the account name or password."
    case .badImpersonationLevel:
      return "The server refused this request. Try again."
    case .ioTimeout:
      return "The server did not respond in time. Try again."
    case .fileIsADirectory:
      return "That name is a folder, not a file."
    case .notSupported:
      return "The server does not support this operation."
    case .networkNameDeleted:
      return "This share is no longer available. Reconnect and try again."
    case .badNetworkName:
      return "This share is not on the server. Choose another share."
    case .directoryNotEmpty:
      return "The folder on the server is not empty. Remove its contents first."
    case .notADirectory:
      return "That name is a file, not a folder."
    case .fileClosed:
      return "This file is no longer open. Try again."
    case .userSessionDeleted:
      return "This session is no longer valid. Sign in again."
    case .connectionRefused:
      return "The server refused the connection. Check the address and try again."
    case .networkSessionExpired:
      return "The session expired. Sign in again."
    case .fileSystemLimitation:
      return "The server cannot finish this because of a limit. Try a smaller item or another location."
    case .smbTooManyUIDs:
      return "Too many sessions are open on this server. Disconnect one and try again."
    default:
      return "The server refused this request. Try again."
    }
  }
}

extension NTStatus: CustomDebugStringConvertible {
  public var debugDescription: String {
    switch ErrorCode(rawValue: rawValue) {
    case .success:
      return "SUCCESS"
    case .pending:
      return "PENDING"
    case .invalidSMB:
      return "INVALID_SMB"
    case .smbBadTid:
      return "SMB_BAD_TID"
    case .smbBadCommand:
      return "SMB_BAD_COMMAND"
    case .smbBadUID:
      return "SMB_BAD_UID"
    case .smbUseStandard:
      return "SMB_USE_STANDARD"
    case .bufferOverflow:
      return "BUFFER_OVERFLOW"
    case .noMoreFiles:
      return "NO_MORE_FILES"
    case .stoppedOnSymlink:
      return "STOPPED_ON_SYMLINK"
    case .notImplemented:
      return "NOT_IMPLEMENTED"
    case .invalidInfoClass:
      return "INVALID_INFO_CLASS"
    case .invalidParameter:
      return "INVALID_PARAMETER"
    case .noSuchDevice:
      return "NO_SUCH_DEVICE"
    case .noSuchFile:
      return "NO_SUCH_FILE"
    case .invalidDeviceRequest:
      return "INVALID_DEVICE_REQUEST"
    case .endOfFile:  
      return "END_OF_FILE"
    case .moreProcessingRequired: 
      return "MORE_PROCESSING_REQUIRED"
    case .accessDenied:
      return "ACCESS_DENIED"
    case .bufferTooSmall:
      return "BUFFER_TOO_SMALL"
    case .objectNameInvalid:
      return "OBJECT_NAME_INVALID"
    case .objectNameNotFound:
      return "OBJECT_NAME_NOT_FOUND"
    case .objectNameCollision:
      return "OBJECT_NAME_COLLISION"
    case .sharingViolation:
      return "SHARING_VIOLATION"
    case .deletePending:
      return "DELETE_PENDING"
    case .objectPathNotFound: 
      return "OBJECT_PATH_NOT_FOUND"
    case .logonFailure:
      return "LOGON_FAILURE"
    case .badImpersonationLevel:
      return "BAD_IMPERSONATION_LEVEL"
    case .ioTimeout:
      return "IO_TIMEOUT"
    case .fileIsADirectory:
      return "FILE_IS_A_DIRECTORY"
    case .notSupported:
      return "NOT_SUPPORTED"
    case .networkNameDeleted:
      return "NETWORK_NAME_DELETED"
    case .badNetworkName:
      return "BAD_NETWORK_NAME"
    case .directoryNotEmpty:
      return "DIRECTORY_NOT_EMPTY"
    case .notADirectory:
      return "NOT_A_DIRECTORY"
    case .fileClosed:
      return "FILE_CLOSED"
    case .userSessionDeleted:
      return "USER_SESSION_DELETED"
    case .connectionRefused:
      return "CONNECTION_REFUSED"
    case .networkSessionExpired:
      return "NETWORK_SESSION_EXPIRED"
    case .fileSystemLimitation:
      return "FILE_SYSTEM_LIMITATION"
    case .smbTooManyUIDs:
      return "SMB_TOO_MANY_UIDS"
    default:
      return "UNKNOWN_ERROR"
    }
  }
}

public enum ErrorCode: UInt32 {
  case success = 0x00000000
  case pending = 0x00000103
  case invalidSMB = 0x00010002
  case smbBadTid = 0x00050002
  case smbBadCommand = 0x00160002
  case smbBadUID = 0x005B0002
  case smbUseStandard = 0x00FB0002
  case bufferOverflow = 0x80000005
  case noMoreFiles = 0x80000006
  case stoppedOnSymlink = 0x8000002D
  case notImplemented = 0xC0000002
  case invalidInfoClass = 0xC0000003
  case invalidParameter = 0xC000000D
  case noSuchDevice = 0xC000000E
  case noSuchFile = 0xC000000F
  case invalidDeviceRequest = 0xC0000010
  case endOfFile = 0xC0000011
  case moreProcessingRequired = 0xC0000016
  case accessDenied = 0xC0000022
  case bufferTooSmall = 0xC0000023
  case objectNameInvalid = 0xC0000033
  case objectNameNotFound = 0xC0000034
  case objectNameCollision = 0xC0000035
  case sharingViolation = 0xC0000043
  case deletePending = 0xC0000056
  case objectPathNotFound = 0xC000003A
  case logonFailure = 0xC000006D
  case badImpersonationLevel = 0xC00000A5
  case ioTimeout = 0xC00000B5
  case fileIsADirectory = 0xC00000BA
  case notSupported = 0xC00000BB
  case networkNameDeleted = 0xC00000C9
  case badNetworkName = 0xC00000CC
  case directoryNotEmpty = 0xC0000101
  case notADirectory = 0xC0000103
  case fileClosed = 0xC0000128
  case userSessionDeleted = 0xC0000203
  case connectionRefused = 0xC0000236
  case networkSessionExpired = 0xC000035C
  case fileSystemLimitation = 0xC0000427
  case smbTooManyUIDs = 0xC000205A
}

public func ==(lhs: NTStatus, rhs: ErrorCode) -> Bool {
  return lhs.rawValue == rhs.rawValue
}

public func ==(lhs: ErrorCode, rhs: NTStatus) -> Bool {
  return lhs.rawValue == rhs.rawValue
}

public func !=(lhs: NTStatus, rhs: ErrorCode) -> Bool {
  return lhs.rawValue != rhs.rawValue
}

public func !=(lhs: ErrorCode, rhs: NTStatus) -> Bool {
  return lhs.rawValue != rhs.rawValue
}

public func ~=(pattern: ErrorCode, value: NTStatus) -> Bool {
  return pattern.rawValue == value.rawValue
}
