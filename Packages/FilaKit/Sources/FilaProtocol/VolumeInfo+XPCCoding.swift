#if canImport(XPC)
    import Foundation
    import XPC

    // `MountPoint` and `VolumeInfo` describe the same mounted volume from two
    // distances, and they share `VolumeKey`, so their coding stays in one file.

    private enum VolumeKey {
        static let mountPoint = "m"
        static let device = "d"
        static let type = "t"
        static let total = "s"
        static let available = "a"
        static let readOnly = "ro"
        static let identifier = "i"
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
            self.init(
                path: String(cString: path),
                device: String(cString: device),
                filesystem: String(cString: filesystem),
                isReadOnly: xpc_dictionary_get_bool(dictionary, VolumeKey.readOnly)
            )
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
#endif
