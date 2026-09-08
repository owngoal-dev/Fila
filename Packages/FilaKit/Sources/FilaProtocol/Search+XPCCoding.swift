#if canImport(XPC)
    import Foundation
    import XPC

    private enum MatchKey {
        static let directory = "d"
        static let node = "n"
    }

    // MARK: - SearchQuery

    public extension SearchQuery {
        /// Into the request dictionary itself, beside the job's own fields: a job
        /// carries at most one query and nesting it would buy nothing.
        func encode(into request: xpc_object_t) {
            xpc_dictionary_set_string(request, FilaWireKey.searchText, text)
            xpc_dictionary_set_bool(request, FilaWireKey.searchCaseSensitive, isCaseSensitive)
            xpc_dictionary_set_bool(request, FilaWireKey.searchHidden, includesHidden)
            xpc_dictionary_set_bool(request, FilaWireKey.searchGlob, isGlob)
        }

        /// Nil when the request carries no query, which is every job but a search.
        init?(decoding request: xpc_object_t) {
            guard let text = xpc_dictionary_get_string(request, FilaWireKey.searchText) else { return nil }
            self.init(
                text: String(cString: text),
                isCaseSensitive: xpc_dictionary_get_bool(request, FilaWireKey.searchCaseSensitive),
                includesHidden: xpc_dictionary_get_bool(request, FilaWireKey.searchHidden),
                isGlob: xpc_dictionary_get_bool(request, FilaWireKey.searchGlob)
            )
        }
    }

    // MARK: - SearchBatch

    public extension SearchBatch {
        /// Its own message on the peer connection, like a job event and for the
        /// same reason: the batch arrives while the request that started the search
        /// is long answered.
        func encoded(jobIdentifier: UInt64) -> xpc_object_t {
            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(message, FilaWireKey.operation, FilaOperation.searchResult.rawValue)
            xpc_dictionary_set_uint64(message, FilaWireKey.jobIdentifier, jobIdentifier)
            xpc_dictionary_set_uint64(message, FilaWireKey.searchLimits, limits.rawValue)
            let array = xpc_array_create(nil, 0)
            for match in matches {
                let entry = xpc_dictionary_create(nil, nil, 0)
                xpc_dictionary_set_string(entry, MatchKey.directory, match.directory)
                xpc_dictionary_set_value(entry, MatchKey.node, match.node.encoded())
                xpc_array_set_value(array, FilaXPC.arrayAppend, entry)
            }
            xpc_dictionary_set_value(message, FilaWireKey.matches, array)
            return message
        }

        /// Returns nil when the message is not a search result.
        static func decode(_ message: xpc_object_t) -> (jobIdentifier: UInt64, batch: SearchBatch)? {
            guard xpc_get_type(message) == FilaXPC.typeDictionary else { return nil }
            guard xpc_dictionary_get_uint64(message, FilaWireKey.operation) == FilaOperation.searchResult.rawValue
            else {
                return nil
            }
            var matches: [SearchMatch] = []
            if let array = xpc_dictionary_get_array(message, FilaWireKey.matches) {
                matches.reserveCapacity(xpc_array_get_count(array))
                for index in 0 ..< xpc_array_get_count(array) {
                    let entry = xpc_array_get_value(array, index)
                    guard let directory = xpc_dictionary_get_string(entry, MatchKey.directory),
                          let value = xpc_dictionary_get_value(entry, MatchKey.node),
                          let node = FileNode(decoding: value) else { continue }
                    matches.append(SearchMatch(directory: String(cString: directory), node: node))
                }
            }
            return (
                xpc_dictionary_get_uint64(message, FilaWireKey.jobIdentifier),
                SearchBatch(
                    matches: matches,
                    limits: SearchLimits(rawValue: xpc_dictionary_get_uint64(message, FilaWireKey.searchLimits))
                )
            )
        }
    }
#endif
