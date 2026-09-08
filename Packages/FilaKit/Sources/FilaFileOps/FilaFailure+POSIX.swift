import Darwin
import FilaProtocol
import Foundation

/// Turning a failed syscall into the one error type that crosses the wire.
///
/// The mapping is small on purpose. `errno` travels intact for the message the
/// user reads, so a distinct `FilaReplyCode` exists only where the *client*
/// behaves differently: `.notFound` gets a different empty state, `.notPermitted`
/// a different one again, and everything else is "it failed, here is why".
public extension FilaFailure {
    /// Reads `errno` at the point of call — so call it immediately after the
    /// syscall that failed and before anything else that could set it.
    init(errno code: Int32 = Darwin.errno, path: String? = nil) {
        switch code {
        case ENOENT, ENOTDIR:
            self.init(code: .notFound, systemError: code, path: path)
        case EACCES, EPERM, EROFS:
            self.init(code: .notPermitted, systemError: code, path: path)
        case ECANCELED:
            self.init(code: .cancelled, systemError: code, path: path)
        default:
            self.init(code: .operationFailed, systemError: code, path: path)
        }
    }
}

/// Runs a syscall that reports failure as a negative return, and throws with
/// the `errno` it left behind.
@discardableResult
public func filaCheck(_ path: String?, _ body: () -> Int32) throws -> Int32 {
    let result = body()
    guard result >= 0 else { throw FilaFailure(errno: Darwin.errno, path: path) }
    return result
}
