/// One entry in the backend's kernel mount table. No file contents or guessed paths.
public struct MountPoint: Sendable, Hashable {
    public var path: String
    public var device: String
    public var filesystem: String
    public var isReadOnly: Bool

    public init(path: String, device: String, filesystem: String, isReadOnly: Bool) {
        self.path = path
        self.device = device
        self.filesystem = filesystem
        self.isReadOnly = isReadOnly
    }
}
