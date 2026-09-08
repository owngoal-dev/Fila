#if canImport(XPC)
    import Foundation
    import XPC

    // MARK: - Failure

    public extension FilaFailure {
        func encode(into reply: xpc_object_t) {
            xpc_dictionary_set_int64(reply, FilaWireKey.code, code.rawValue)
            xpc_dictionary_set_int64(reply, FilaWireKey.errno, Int64(systemError))
            if let path {
                xpc_dictionary_set_string(reply, FilaWireKey.path, path)
            }
            if let reason {
                xpc_dictionary_set_string(reply, FilaWireKey.failureReason, reason.rawValue)
            }
        }

        /// The failure a reply carries, or nil when it says `.success`.
        static func decode(_ reply: xpc_object_t) -> FilaFailure? {
            let code = FilaReplyCode(rawValue: xpc_dictionary_get_int64(reply, FilaWireKey.code)) ?? .operationFailed
            guard code != .success else { return nil }
            return FilaFailure(
                code: code,
                systemError: Int32(truncatingIfNeeded: xpc_dictionary_get_int64(reply, FilaWireKey.errno)),
                path: xpc_dictionary_get_string(reply, FilaWireKey.path).map { String(cString: $0) },
                reason: xpc_dictionary_get_string(reply, FilaWireKey.failureReason)
                    .flatMap { FilaFailureReason(rawValue: String(cString: $0)) }
            )
        }
    }
#endif
