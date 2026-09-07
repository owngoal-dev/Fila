#if canImport(XPC)
import Foundation
import XPC

// The one place the wire layout of a value is written down. Both ends compile
// this file, so a field added on one side cannot go missing on the other — the
// failure mode a hand-rolled encoder on each side eventually produces.
//
// Keys inside these dictionaries are one or two characters on purpose: a
// directory page carries 512 of them and the name is repeated in every entry.

private enum NodeKey {
    static let name = "n"
    static let kind = "k"
    static let size = "s"
    static let allocated = "a"
    static let modified = "m"
    static let created = "c"
    static let accessed = "x"
    static let mode = "p"
    static let owner = "u"
    static let group = "g"
    static let flags = "f"
    static let links = "l"
    static let inode = "i"
    static let linkTarget = "t"
    static let linkKind = "r"
}

private enum DetailKey {
    static let path = "p"
    static let node = "n"
    static let xattrNames = "xn"
    static let xattrSizes = "xs"
    static let acl = "acl"
    static let protected = "prot"
}

private enum VolumeKey {
    static let mountPoint = "m"
    static let device = "d"
    static let type = "t"
    static let total = "s"
    static let available = "a"
    static let readOnly = "ro"
    static let identifier = "i"
}

private enum MatchKey {
    static let directory = "d"
    static let node = "n"
}

private enum ChangeKey {
    static let mode = "m"
    static let owner = "u"
    static let group = "g"
    static let modified = "mt"
    static let accessed = "at"
    static let flags = "f"
    static let xattrName = "xn"
    static let xattrValue = "xv"
    static let recursive = "r"
}

// MARK: - FileNode

public extension FileNode {
    func encoded() -> xpc_object_t {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(dictionary, NodeKey.name, name)
        xpc_dictionary_set_uint64(dictionary, NodeKey.kind, kind.rawValue)
        xpc_dictionary_set_int64(dictionary, NodeKey.size, size)
        xpc_dictionary_set_int64(dictionary, NodeKey.allocated, allocatedSize)
        xpc_dictionary_set_double(dictionary, NodeKey.modified, modified)
        xpc_dictionary_set_double(dictionary, NodeKey.created, created)
        xpc_dictionary_set_double(dictionary, NodeKey.accessed, accessed)
        xpc_dictionary_set_uint64(dictionary, NodeKey.mode, UInt64(mode))
        xpc_dictionary_set_uint64(dictionary, NodeKey.owner, UInt64(ownerID))
        xpc_dictionary_set_uint64(dictionary, NodeKey.group, UInt64(groupID))
        xpc_dictionary_set_uint64(dictionary, NodeKey.flags, UInt64(systemFlags))
        xpc_dictionary_set_uint64(dictionary, NodeKey.links, linkCount)
        xpc_dictionary_set_uint64(dictionary, NodeKey.inode, inode)
        if let link {
            xpc_dictionary_set_string(dictionary, NodeKey.linkTarget, link.target)
            // A broken link has no resolved kind, and `.unknown` is a real
            // answer for a file whose type we could not read — so absence, not
            // a sentinel, is what carries "broken" across.
            if let resolved = link.resolvedKind {
                xpc_dictionary_set_uint64(dictionary, NodeKey.linkKind, resolved.rawValue)
            }
        }
        return dictionary
    }

    init?(decoding dictionary: xpc_object_t) {
        guard xpc_get_type(dictionary) == FilaXPC.typeDictionary else { return nil }
        guard let name = xpc_dictionary_get_string(dictionary, NodeKey.name) else { return nil }
        var link: SymbolicLink?
        if let target = xpc_dictionary_get_string(dictionary, NodeKey.linkTarget) {
            var resolved: FileKind?
            if xpc_dictionary_get_value(dictionary, NodeKey.linkKind) != nil {
                resolved = FileKind(rawValue: xpc_dictionary_get_uint64(dictionary, NodeKey.linkKind))
            }
            link = SymbolicLink(target: String(cString: target), resolvedKind: resolved)
        }
        self.init(
            name: String(cString: name),
            kind: FileKind(rawValue: xpc_dictionary_get_uint64(dictionary, NodeKey.kind)) ?? .unknown,
            size: xpc_dictionary_get_int64(dictionary, NodeKey.size),
            allocatedSize: xpc_dictionary_get_int64(dictionary, NodeKey.allocated),
            modified: xpc_dictionary_get_double(dictionary, NodeKey.modified),
            created: xpc_dictionary_get_double(dictionary, NodeKey.created),
            accessed: xpc_dictionary_get_double(dictionary, NodeKey.accessed),
            mode: mode_t(truncatingIfNeeded: xpc_dictionary_get_uint64(dictionary, NodeKey.mode)),
            ownerID: uid_t(truncatingIfNeeded: xpc_dictionary_get_uint64(dictionary, NodeKey.owner)),
            groupID: gid_t(truncatingIfNeeded: xpc_dictionary_get_uint64(dictionary, NodeKey.group)),
            systemFlags: UInt32(truncatingIfNeeded: xpc_dictionary_get_uint64(dictionary, NodeKey.flags)),
            linkCount: xpc_dictionary_get_uint64(dictionary, NodeKey.links),
            inode: xpc_dictionary_get_uint64(dictionary, NodeKey.inode),
            link: link
        )
    }
}

// MARK: - FileDetails

public extension FileDetails {
    func encoded() -> xpc_object_t {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(dictionary, DetailKey.path, path)
        xpc_dictionary_set_value(dictionary, DetailKey.node, node.encoded())
        let names = xpc_array_create(nil, 0)
        let sizes = xpc_array_create(nil, 0)
        for attribute in extendedAttributes {
            xpc_array_set_string(names, FilaXPC.arrayAppend, attribute.name)
            xpc_array_set_int64(sizes, FilaXPC.arrayAppend, attribute.byteCount)
        }
        xpc_dictionary_set_value(dictionary, DetailKey.xattrNames, names)
        xpc_dictionary_set_value(dictionary, DetailKey.xattrSizes, sizes)
        xpc_dictionary_set_bool(dictionary, DetailKey.acl, hasAccessControlList)
        xpc_dictionary_set_bool(dictionary, DetailKey.protected, isDestructionProtected)
        return dictionary
    }

    init?(decoding dictionary: xpc_object_t) {
        guard xpc_get_type(dictionary) == FilaXPC.typeDictionary else { return nil }
        guard let path = xpc_dictionary_get_string(dictionary, DetailKey.path) else { return nil }
        guard let nodeValue = xpc_dictionary_get_value(dictionary, DetailKey.node),
              let node = FileNode(decoding: nodeValue) else { return nil }

        var attributes: [ExtendedAttribute] = []
        if let names = xpc_dictionary_get_array(dictionary, DetailKey.xattrNames),
           let sizes = xpc_dictionary_get_array(dictionary, DetailKey.xattrSizes) {
            for index in 0 ..< xpc_array_get_count(names) {
                guard let name = xpc_array_get_string(names, index) else { continue }
                attributes.append(ExtendedAttribute(
                    name: String(cString: name),
                    byteCount: index < xpc_array_get_count(sizes) ? xpc_array_get_int64(sizes, index) : 0
                ))
            }
        }

        self.init(
            path: String(cString: path),
            node: node,
            extendedAttributes: attributes,
            hasAccessControlList: xpc_dictionary_get_bool(dictionary, DetailKey.acl),
            isDestructionProtected: xpc_dictionary_get_bool(dictionary, DetailKey.protected)
        )
    }
}

public extension MountPoint {
    func encoded() -> xpc_object_t {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(dictionary, VolumeKey.mountPoint, path)
        xpc_dictionary_set_string(dictionary, VolumeKey.device, device)
        xpc_dictionary_set_string(dictionary, VolumeKey.type, filesystem)
        xpc_dictionary_set_bool(dictionary, VolumeKey.readOnly, isReadOnly)
        return dictionary
    }

    init?(decoding dictionary: xpc_object_t) {
        guard xpc_get_type(dictionary) == FilaXPC.typeDictionary,
              let path = xpc_dictionary_get_string(dictionary, VolumeKey.mountPoint),
              let device = xpc_dictionary_get_string(dictionary, VolumeKey.device),
              let filesystem = xpc_dictionary_get_string(dictionary, VolumeKey.type) else { return nil }
        self.init(path: String(cString: path), device: String(cString: device),
                  filesystem: String(cString: filesystem), isReadOnly: xpc_dictionary_get_bool(dictionary, VolumeKey.readOnly))
    }
}

// MARK: - VolumeInfo

public extension VolumeInfo {
    func encoded() -> xpc_object_t {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(dictionary, VolumeKey.mountPoint, mountPoint)
        xpc_dictionary_set_string(dictionary, VolumeKey.device, deviceName)
        xpc_dictionary_set_string(dictionary, VolumeKey.type, filesystemType)
        xpc_dictionary_set_int64(dictionary, VolumeKey.total, totalByteCount)
        xpc_dictionary_set_int64(dictionary, VolumeKey.available, availableByteCount)
        xpc_dictionary_set_bool(dictionary, VolumeKey.readOnly, isReadOnly)
        xpc_dictionary_set_uint64(dictionary, VolumeKey.identifier, deviceIdentifier)
        return dictionary
    }

    init?(decoding dictionary: xpc_object_t) {
        guard xpc_get_type(dictionary) == FilaXPC.typeDictionary else { return nil }
        guard let mountPoint = xpc_dictionary_get_string(dictionary, VolumeKey.mountPoint),
              let device = xpc_dictionary_get_string(dictionary, VolumeKey.device),
              let type = xpc_dictionary_get_string(dictionary, VolumeKey.type) else { return nil }
        self.init(
            mountPoint: String(cString: mountPoint),
            deviceName: String(cString: device),
            filesystemType: String(cString: type),
            totalByteCount: xpc_dictionary_get_int64(dictionary, VolumeKey.total),
            availableByteCount: xpc_dictionary_get_int64(dictionary, VolumeKey.available),
            isReadOnly: xpc_dictionary_get_bool(dictionary, VolumeKey.readOnly),
            deviceIdentifier: xpc_dictionary_get_uint64(dictionary, VolumeKey.identifier)
        )
    }
}

// MARK: - NodeTemplate

public extension NodeTemplate {
    /// Written into the request dictionary itself rather than a nested one:
    /// `createNode` carries a path and this, and nothing else.
    func encode(into request: xpc_object_t) {
        switch self {
        case .directory:
            xpc_dictionary_set_uint64(request, FilaWireKey.nodeKind, FileKind.directory.rawValue)
        case .emptyFile:
            xpc_dictionary_set_uint64(request, FilaWireKey.nodeKind, FileKind.regular.rawValue)
        case let .symbolicLink(target):
            xpc_dictionary_set_uint64(request, FilaWireKey.nodeKind, FileKind.symbolicLink.rawValue)
            xpc_dictionary_set_string(request, FilaWireKey.linkTarget, target)
        case let .hardLink(existing):
            // A hard link is a second name for one inode, so the wire says
            // "another link" by naming what it links to; `linkCount` is what
            // makes it visible afterwards.
            xpc_dictionary_set_uint64(request, FilaWireKey.nodeKind, FileKind.unknown.rawValue)
            xpc_dictionary_set_string(request, FilaWireKey.linkTarget, existing)
        }
    }

    init?(decoding request: xpc_object_t) {
        let kind = FileKind(rawValue: xpc_dictionary_get_uint64(request, FilaWireKey.nodeKind)) ?? .unknown
        let target = xpc_dictionary_get_string(request, FilaWireKey.linkTarget).map { String(cString: $0) }
        switch kind {
        case .directory: self = .directory
        case .regular: self = .emptyFile
        case .symbolicLink:
            guard let target else { return nil }
            self = .symbolicLink(target: target)
        case .unknown:
            guard let target else { return nil }
            self = .hardLink(existing: target)
        default:
            return nil
        }
    }
}

// MARK: - AttributeChange

public extension AttributeChange {
    func encoded() -> xpc_object_t {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        if let mode { xpc_dictionary_set_uint64(dictionary, ChangeKey.mode, UInt64(mode)) }
        if let ownerID { xpc_dictionary_set_uint64(dictionary, ChangeKey.owner, UInt64(ownerID)) }
        if let groupID { xpc_dictionary_set_uint64(dictionary, ChangeKey.group, UInt64(groupID)) }
        if let modified { xpc_dictionary_set_double(dictionary, ChangeKey.modified, modified) }
        if let accessed { xpc_dictionary_set_double(dictionary, ChangeKey.accessed, accessed) }
        if let systemFlags { xpc_dictionary_set_uint64(dictionary, ChangeKey.flags, UInt64(systemFlags)) }
        if let extendedAttribute {
            xpc_dictionary_set_string(dictionary, ChangeKey.xattrName, extendedAttribute.name)
            if let value = extendedAttribute.value {
                value.withUnsafeBytes { buffer in
                    xpc_dictionary_set_data(dictionary, ChangeKey.xattrValue, buffer.baseAddress, buffer.count)
                }
            }
        }
        xpc_dictionary_set_bool(dictionary, ChangeKey.recursive, isRecursive)
        return dictionary
    }

    init?(decoding dictionary: xpc_object_t) {
        guard xpc_get_type(dictionary) == FilaXPC.typeDictionary else { return nil }
        func optionalUInt64(_ key: String) -> UInt64? {
            xpc_dictionary_get_value(dictionary, key) == nil ? nil : xpc_dictionary_get_uint64(dictionary, key)
        }
        func optionalDouble(_ key: String) -> Double? {
            xpc_dictionary_get_value(dictionary, key) == nil ? nil : xpc_dictionary_get_double(dictionary, key)
        }

        var attribute: (name: String, value: Data?)?
        if let name = xpc_dictionary_get_string(dictionary, ChangeKey.xattrName) {
            var length = 0
            let bytes = xpc_dictionary_get_data(dictionary, ChangeKey.xattrValue, &length)
            attribute = (
                String(cString: name),
                bytes.map { Data(bytes: $0, count: length) }
            )
        }

        self.init(
            mode: optionalUInt64(ChangeKey.mode).map { mode_t(truncatingIfNeeded: $0) },
            ownerID: optionalUInt64(ChangeKey.owner).map { uid_t(truncatingIfNeeded: $0) },
            groupID: optionalUInt64(ChangeKey.group).map { gid_t(truncatingIfNeeded: $0) },
            modified: optionalDouble(ChangeKey.modified),
            accessed: optionalDouble(ChangeKey.accessed),
            systemFlags: optionalUInt64(ChangeKey.flags).map { UInt32(truncatingIfNeeded: $0) },
            extendedAttribute: attribute,
            isRecursive: xpc_dictionary_get_bool(dictionary, ChangeKey.recursive)
        )
    }
}

// MARK: - JobRequest

public extension JobRequest {
    func encode(into request: xpc_object_t) {
        xpc_dictionary_set_uint64(request, FilaWireKey.jobKind, kind.rawValue)
        let array = xpc_array_create(nil, 0)
        for source in sources { xpc_array_set_string(array, FilaXPC.arrayAppend, source) }
        xpc_dictionary_set_value(request, FilaWireKey.sources, array)
        if let destination { xpc_dictionary_set_string(request, FilaWireKey.destination, destination) }
        xpc_dictionary_set_bool(request, FilaWireKey.useTrash, useTrash)
        xpc_dictionary_set_bool(request, FilaWireKey.overwrite, overwrite)
        xpc_dictionary_set_bool(request, FilaWireKey.overrideGuard, overrideGuard)
        query?.encode(into: request)
        archive?.encode(into: request)
    }

    init?(decoding request: xpc_object_t) {
        guard let kind = FilaJobKind(rawValue: xpc_dictionary_get_uint64(request, FilaWireKey.jobKind)) else { return nil }
        guard let array = xpc_dictionary_get_array(request, FilaWireKey.sources) else { return nil }
        var sources: [String] = []
        for index in 0 ..< xpc_array_get_count(array) {
            guard let value = xpc_array_get_string(array, index) else { return nil }
            sources.append(String(cString: value))
        }
        guard !sources.isEmpty else { return nil }
        self.init(
            kind: kind,
            sources: sources,
            destination: xpc_dictionary_get_string(request, FilaWireKey.destination).map { String(cString: $0) },
            useTrash: xpc_dictionary_get_bool(request, FilaWireKey.useTrash),
            overwrite: xpc_dictionary_get_bool(request, FilaWireKey.overwrite),
            overrideGuard: xpc_dictionary_get_bool(request, FilaWireKey.overrideGuard),
            query: SearchQuery(decoding: request),
            archive: ArchiveOptions(decoding: request)
        )
    }
}

// MARK: - ArchiveOptions

public extension ArchiveOptions {
    /// Beside the job's own fields, like a search query and for the same
    /// reason: a job carries at most one.
    func encode(into request: xpc_object_t) {
        xpc_dictionary_set_string(request, FilaWireKey.archiveFormat, format.rawValue)
        xpc_dictionary_set_string(request, FilaWireKey.zipCompression, zipCompression.rawValue)
        xpc_dictionary_set_string(request, FilaWireKey.zipEncryption, encryption.rawValue)
        if let password { xpc_dictionary_set_string(request, FilaWireKey.archivePassword, password) }
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
            members: members
        )
    }
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
        guard xpc_dictionary_get_uint64(message, FilaWireKey.operation) == FilaOperation.searchResult.rawValue else {
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
            xpc_dictionary_set_int64(message, FilaWireKey.code, failure.code.rawValue)
            xpc_dictionary_set_int64(message, FilaWireKey.errno, Int64(failure.systemError))
            if let path = failure.path { xpc_dictionary_set_string(message, FilaWireKey.path, path) }
        }
        return message
    }

    /// Returns nil when the message is not a job event.
    static func decode(_ message: xpc_object_t) -> (jobIdentifier: UInt64, event: JobEvent)? {
        guard xpc_get_type(message) == FilaXPC.typeDictionary else { return nil }
        guard xpc_dictionary_get_uint64(message, FilaWireKey.operation) == FilaOperation.jobEvent.rawValue else { return nil }
        let identifier = xpc_dictionary_get_uint64(message, FilaWireKey.jobIdentifier)
        let path = xpc_dictionary_get_string(message, FilaWireKey.path).map { String(cString: $0) }
        if xpc_dictionary_get_bool(message, FilaWireKey.jobPhase) {
            let code = FilaReplyCode(rawValue: xpc_dictionary_get_int64(message, FilaWireKey.code)) ?? .operationFailed
            return (identifier, .completed(FilaFailure(
                code: code,
                systemError: Int32(truncatingIfNeeded: xpc_dictionary_get_int64(message, FilaWireKey.errno)),
                path: path
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

// MARK: - Failure

public extension FilaFailure {
    func encode(into reply: xpc_object_t) {
        xpc_dictionary_set_int64(reply, FilaWireKey.code, code.rawValue)
        xpc_dictionary_set_int64(reply, FilaWireKey.errno, Int64(systemError))
        if let path { xpc_dictionary_set_string(reply, FilaWireKey.path, path) }
    }

    /// The failure a reply carries, or nil when it says `.success`.
    static func decode(_ reply: xpc_object_t) -> FilaFailure? {
        let code = FilaReplyCode(rawValue: xpc_dictionary_get_int64(reply, FilaWireKey.code)) ?? .operationFailed
        guard code != .success else { return nil }
        return FilaFailure(
            code: code,
            systemError: Int32(truncatingIfNeeded: xpc_dictionary_get_int64(reply, FilaWireKey.errno)),
            path: xpc_dictionary_get_string(reply, FilaWireKey.path).map { String(cString: $0) }
        )
    }
}
#endif
