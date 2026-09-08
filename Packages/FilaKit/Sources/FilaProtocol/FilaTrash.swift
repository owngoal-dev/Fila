/// Where deleted items go, and how they remember where they came from.
///
/// Fila's own directory rather than the system `.Trash/<uid>`: on a jailbroken
/// device nothing else empties, lists or expects that layout, and a name of
/// our own says whose it is. One level, no per-uid split — the daemon and the
/// in-process backend never share a device.
public enum FilaTrash {
    /// Under the bootstrap of a relocated daemon, else under the volume
    /// mount point. Sources may live on a different volume.
    public static let directoryName = ".fila-trash"

    /// Set on a trashed item by the job that renamed it, holding the canonical
    /// path it was renamed away from. Read back by Put Back; removed again once
    /// the item is home. Absent where it could not be set, and then the item
    /// can only be deleted for good or moved out by hand.
    public static let originAttribute = "wiki.qaq.fila.origin"

    /// A batch identity, paired with the origin for Undo even when copying changes the inode.
    public static let jobAttribute = "wiki.qaq.fila.trash-job"

    public static func directory(under base: String) -> String {
        base == "/" ? "/" + directoryName : base + "/" + directoryName
    }
}
