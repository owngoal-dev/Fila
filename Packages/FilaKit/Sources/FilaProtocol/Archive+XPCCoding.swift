#if canImport(XPC)
    import Foundation
    import XPC

    // MARK: - ArchiveOptions

    public extension ArchiveOptions {
        /// Beside the job's own fields, like a search query and for the same
        /// reason: a job carries at most one.
        func encode(into request: xpc_object_t) {
            xpc_dictionary_set_string(request, FilaWireKey.archiveFormat, format.rawValue)
            xpc_dictionary_set_string(request, FilaWireKey.zipCompression, zipCompression.rawValue)
            xpc_dictionary_set_string(request, FilaWireKey.zipEncryption, encryption.rawValue)
            if let password {
                xpc_dictionary_set_string(request, FilaWireKey.archivePassword, password)
            }
            if let organizeExtraction {
                xpc_dictionary_set_bool(request, FilaWireKey.archiveOrganizeExtraction, organizeExtraction)
            }
            guard let members else { return }
            let array = xpc_array_create(nil, 0)
            for member in members {
                let entry = xpc_dictionary_create(nil, nil, 0)
                xpc_dictionary_set_int64(entry, FilaWireKey.memberIndex, member.index)
                xpc_dictionary_set_string(entry, FilaWireKey.memberPath, member.declaredPath)
                xpc_array_set_value(array, FilaXPC.arrayAppend, entry)
            }
            xpc_dictionary_set_value(request, FilaWireKey.archiveMembers, array)
        }

        /// Nil when the request carries no archive options, which is every job
        /// but a compress or an extract.
        init?(decoding request: xpc_object_t) {
            guard let rawFormat = xpc_dictionary_get_string(request, FilaWireKey.archiveFormat),
                  let format = ArchiveFormat(rawValue: String(cString: rawFormat)),
                  let rawCompression = xpc_dictionary_get_string(request, FilaWireKey.zipCompression),
                  let zipCompression = ZipCompression(rawValue: String(cString: rawCompression)),
                  let rawEncryption = xpc_dictionary_get_string(request, FilaWireKey.zipEncryption),
                  let encryption = ZipEncryption(rawValue: String(cString: rawEncryption)) else { return nil }
            var members: [ArchiveSelection]?
            if let array = xpc_dictionary_get_array(request, FilaWireKey.archiveMembers) {
                var selected: [ArchiveSelection] = []
                for index in 0 ..< xpc_array_get_count(array) {
                    let entry = xpc_array_get_value(array, index)
                    guard let path = xpc_dictionary_get_string(entry, FilaWireKey.memberPath) else { return nil }
                    selected.append(ArchiveSelection(
                        index: xpc_dictionary_get_int64(entry, FilaWireKey.memberIndex),
                        declaredPath: String(cString: path)
                    ))
                }
                members = selected
            }
            self.init(
                format: format,
                zipCompression: zipCompression,
                encryption: encryption,
                password: xpc_dictionary_get_string(request, FilaWireKey.archivePassword).map { String(cString: $0) },
                members: members,
                organizeExtraction: xpc_dictionary_get_value(request, FilaWireKey.archiveOrganizeExtraction) == nil
                    ? nil : xpc_dictionary_get_bool(request, FilaWireKey.archiveOrganizeExtraction)
            )
        }
    }
#endif
