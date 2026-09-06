#if canImport(XPC)
import Dispatch
import XPC

// `xpc_connection_create_mach_service` is not re-exported to Swift, and both
// sides need it: the daemon to listen, the app to connect.

@_silgen_name("xpc_connection_create_mach_service")
public func filaCreateMachServiceConnection(
    _ name: UnsafePointer<CChar>,
    _ targetQueue: DispatchQueue?,
    _ flags: UInt64
) -> xpc_connection_t?

public enum FilaXPCFlag {
    public static let client: UInt64 = 0
    public static let listener: UInt64 = 1 // XPC_CONNECTION_MACH_SERVICE_LISTENER
}
#endif
