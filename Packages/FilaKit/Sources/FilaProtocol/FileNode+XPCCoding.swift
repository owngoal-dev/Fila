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
               let sizes = xpc_dictionary_get_array(dictionary, DetailKey.xattrSizes)
            {
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
            if let mode {
                xpc_dictionary_set_uint64(dictionary, ChangeKey.mode, UInt64(mode))
            }
            if let ownerID {
                xpc_dictionary_set_uint64(dictionary, ChangeKey.owner, UInt64(ownerID))
            }
            if let groupID {
                xpc_dictionary_set_uint64(dictionary, ChangeKey.group, UInt64(groupID))
            }
            if let modified {
                xpc_dictionary_set_double(dictionary, ChangeKey.modified, modified)
            }
            if let accessed {
                xpc_dictionary_set_double(dictionary, ChangeKey.accessed, accessed)
            }
            if let systemFlags {
                xpc_dictionary_set_uint64(dictionary, ChangeKey.flags, UInt64(systemFlags))
            }
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
#endif
