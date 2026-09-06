import Darwin
import FilaProtocol
import Foundation
import XPC

/// The whole trust boundary.
///
/// `filad` runs as root and hands out descriptors to any path on the device, so
/// the only thing that keeps it from being a privilege-escalation service for
/// every app on the system is this check, and it runs before a single request
/// field is read.
///
/// The check is on the kernel's audit token, not on anything the peer told us:
/// the token is filled in by the kernel for the connection, so a caller cannot
/// forge its pid, its uid, or its entitlements.
final class PeerAuthenticator {
    /// A sandboxed App Store app cannot obtain these, and
    /// `wiki.qaq.fila.client` is ours alone.
    private static let requiredEntitlements = [
        FilaProtocol.clientEntitlement,
        "platform-application",
        "com.apple.private.security.no-sandbox",
    ]

    private lazy var clientPaths = FilaProtocol.clientPaths.compactMap {
        filaCanonicalPath(InstallRoot.current + $0)
    }

    /// The peer's pid when it may be served, nil when the connection must be
    /// cancelled.
    func authenticate(_ connection: xpc_connection_t) -> Int32? {
        var token = audit_token_t()
        filaXPCConnectionGetAuditToken(connection, &token)
        let pid = Int32(bitPattern: token.val.5)

        // Identity is the executable on disk, not the bundle id, and the file
        // at that path must be one no less privileged process could have
        // swapped out from under us.
        guard pid > 1,
              (token.val.1 == 0 || token.val.1 == 501),
              hasRequiredEntitlements(token: &token),
              let clientPath = filaProcessPath(pid: pid),
              clientPaths.contains(clientPath),
              isTrustedExecutable(clientPath) else { return nil }
        return pid
    }

    private func hasRequiredEntitlements(token: inout audit_token_t) -> Bool {
        return Self.requiredEntitlements.allSatisfy { entitlement in
            let value = entitlement.withCString { filaXPCCopyEntitlement($0, &token) }
            return value.map { xpc_get_type($0) == XPC_TYPE_BOOL && xpc_bool_get_value($0) } ?? false
        }
    }

    /// A regular, executable file owned by root
    /// and writable by nobody else. If the client binary were group- or
    /// world-writable, admitting it by path would admit whatever anyone chose
    /// to put there.
    private func isTrustedExecutable(_ path: String) -> Bool {
        var metadata = stat()
        guard stat(path, &metadata) == 0 else { return false }
        return metadata.st_uid == 0
            && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && metadata.st_mode & mode_t(S_IXUSR) != 0
            && metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    }
}
