#if canImport(XPC)
    import Foundation
    import XPC

    // MARK: - JobRequest

    public extension JobRequest {
        func encode(into request: xpc_object_t) {
            xpc_dictionary_set_uint64(request, FilaWireKey.jobKind, kind.rawValue)
            let array = xpc_array_create(nil, 0)
            for source in sources {
                xpc_array_set_string(array, FilaXPC.arrayAppend, source)
            }
            xpc_dictionary_set_value(request, FilaWireKey.sources, array)
            if let destination {
                xpc_dictionary_set_string(request, FilaWireKey.destination, destination)
            }
            xpc_dictionary_set_bool(request, FilaWireKey.useTrash, useTrash)
            if let trashID {
                xpc_dictionary_set_string(request, FilaWireKey.trashID, trashID.uuidString)
            }
            xpc_dictionary_set_bool(request, FilaWireKey.overwrite, overwrite)
            xpc_dictionary_set_bool(request, FilaWireKey.overrideGuard, overrideGuard)
            query?.encode(into: request)
            archive?.encode(into: request)
        }

        init?(decoding request: xpc_object_t) {
            guard let kind = FilaJobKind(rawValue: xpc_dictionary_get_uint64(request, FilaWireKey.jobKind))
            else { return nil }
            guard let array = xpc_dictionary_get_array(request, FilaWireKey.sources) else { return nil }
            var sources: [String] = []
            for index in 0 ..< xpc_array_get_count(array) {
                guard let value = xpc_array_get_string(array, index) else { return nil }
                sources.append(String(cString: value))
            }
            guard !sources.isEmpty else { return nil }
            var trashID: UUID?
            if let text = xpc_dictionary_get_string(request, FilaWireKey.trashID) {
                guard let identity = UUID(uuidString: String(cString: text)) else { return nil }
                trashID = identity
            }
            self.init(
                kind: kind,
                sources: sources,
                destination: xpc_dictionary_get_string(request, FilaWireKey.destination).map { String(cString: $0) },
                useTrash: xpc_dictionary_get_bool(request, FilaWireKey.useTrash),
                trashID: trashID,
                overwrite: xpc_dictionary_get_bool(request, FilaWireKey.overwrite),
                overrideGuard: xpc_dictionary_get_bool(request, FilaWireKey.overrideGuard),
                query: SearchQuery(decoding: request),
                archive: ArchiveOptions(decoding: request)
            )
        }
    }

    // MARK: - JobEvent

    public extension JobEvent {
        /// Job events travel as their own message on the peer connection, so the
        /// operation code and the job id go in beside the payload.
        func encoded(jobIdentifier: UInt64) -> xpc_object_t {
            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(message, FilaWireKey.operation, FilaOperation.jobEvent.rawValue)
            xpc_dictionary_set_uint64(message, FilaWireKey.jobIdentifier, jobIdentifier)
            switch self {
            case let .progress(progress):
                xpc_dictionary_set_bool(message, FilaWireKey.jobPhase, false)
                xpc_dictionary_set_int64(message, FilaWireKey.bytesDone, progress.bytesDone)
                xpc_dictionary_set_int64(message, FilaWireKey.bytesTotal, progress.bytesTotal)
                xpc_dictionary_set_int64(message, FilaWireKey.itemsDone, progress.itemsDone)
                xpc_dictionary_set_int64(message, FilaWireKey.itemsTotal, progress.itemsTotal)
                xpc_dictionary_set_string(message, FilaWireKey.path, progress.currentPath)
            case let .completed(failure):
                xpc_dictionary_set_bool(message, FilaWireKey.jobPhase, true)
                failure.encode(into: message)
            }
            return message
        }

        /// Returns nil when the message is not a job event.
        static func decode(_ message: xpc_object_t) -> (jobIdentifier: UInt64, event: JobEvent)? {
            guard xpc_get_type(message) == FilaXPC.typeDictionary else { return nil }
            guard xpc_dictionary_get_uint64(message, FilaWireKey.operation) == FilaOperation.jobEvent.rawValue
            else { return nil }
            let identifier = xpc_dictionary_get_uint64(message, FilaWireKey.jobIdentifier)
            let path = xpc_dictionary_get_string(message, FilaWireKey.path).map { String(cString: $0) }
            if xpc_dictionary_get_bool(message, FilaWireKey.jobPhase) {
                let code = FilaReplyCode(rawValue: xpc_dictionary_get_int64(message, FilaWireKey.code)) ?? .operationFailed
                return (identifier, .completed(FilaFailure(
                    code: code,
                    systemError: Int32(truncatingIfNeeded: xpc_dictionary_get_int64(message, FilaWireKey.errno)),
                    path: path,
                    reason: xpc_dictionary_get_string(message, FilaWireKey.failureReason)
                        .flatMap { FilaFailureReason(rawValue: String(cString: $0)) }
                )))
            }
            return (identifier, .progress(JobProgress(
                bytesDone: xpc_dictionary_get_int64(message, FilaWireKey.bytesDone),
                bytesTotal: xpc_dictionary_get_int64(message, FilaWireKey.bytesTotal),
                itemsDone: xpc_dictionary_get_int64(message, FilaWireKey.itemsDone),
                itemsTotal: xpc_dictionary_get_int64(message, FilaWireKey.itemsTotal),
                currentPath: path ?? ""
            )))
        }
    }
#endif
