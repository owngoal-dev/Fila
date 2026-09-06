import Darwin
import FilaFileOps
import XPC

// The XPC C API the daemon needs and Swift does not re-export. Declared here
// rather than through a bridging header so the target stays a plain Swift tool.

@_silgen_name("proc_pidpath")
func filaProcPIDPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

@_silgen_name("xpc_connection_get_audit_token")
func filaXPCConnectionGetAuditToken(
    _ connection: xpc_connection_t,
    _ token: UnsafeMutablePointer<audit_token_t>
)

@_silgen_name("xpc_copy_entitlement_for_token")
func filaXPCCopyEntitlement(
    _ name: UnsafePointer<CChar>,
    _ token: UnsafeMutablePointer<audit_token_t>
) -> xpc_object_t?

/// `realpath(3)`, or nil when the path does not resolve.
///
/// `FilaPath` owns canonicalisation for the whole project — `/var` and `/etc`
/// are symlinks into `/private` on every Apple platform, and a second
/// implementation is a second chance to compare an unresolved string.
func filaCanonicalPath(_ path: String) -> String? {
    try? FilaPath.resolve(path)
}

/// The executable path of a running process, canonicalised.
func filaProcessPath(pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let length = buffer.withUnsafeMutableBytes {
        filaProcPIDPath(pid, $0.baseAddress!, UInt32($0.count))
    }
    guard length > 0 else { return nil }
    return filaCanonicalPath(String(cString: buffer))
}
