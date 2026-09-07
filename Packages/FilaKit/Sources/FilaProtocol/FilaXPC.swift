#if canImport(XPC)
import CFilaXPC
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

/// The XPC constants, read through C rather than through Swift's XPC overlay.
///
/// Naming the SDK's XPC type, array-append or connection-error macros in Swift links
/// `/usr/lib/swift/libswiftXPC.dylib` as a required library, and iOS 15 does
/// not have it: dyld terminates the app before `main` with "Library not
/// loaded". Through `CFilaXPC` they are the libSystem globals they have always
/// been, the overlay stays weakly linked and unused, and the same binary runs
/// on iOS 15 and on iOS 26. No Swift file in this project may spell them
/// directly; `make check` fails on one that does.
public enum FilaXPC {
    public static var typeArray: xpc_type_t { fila_xpc_type_array() }
    public static var typeBool: xpc_type_t { fila_xpc_type_bool() }
    public static var typeConnection: xpc_type_t { fila_xpc_type_connection() }
    public static var typeDictionary: xpc_type_t { fila_xpc_type_dictionary() }
    public static var typeUInt64: xpc_type_t { fila_xpc_type_uint64() }

    /// The index that appends rather than replaces, for `xpc_array_set_*`.
    public static var arrayAppend: Int { fila_xpc_array_append() }

    public static var errorConnectionInterrupted: xpc_object_t { fila_xpc_error_connection_interrupted() }
    public static var errorConnectionInvalid: xpc_object_t { fila_xpc_error_connection_invalid() }
}
#endif
