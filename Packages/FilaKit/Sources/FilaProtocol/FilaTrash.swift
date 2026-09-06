/// Where deleted items go, and how they remember where they came from.
///
/// Fila's own directory rather than the system `.Trash/<uid>`: on a jailbroken
/// device nothing else empties, lists or expects that layout, and a name of
/// our own says whose it is. One level, no per-uid split — the daemon and the
/// in-process backend never share a device.
public enum FilaTrash {
    /// Under the writable root of a relocated daemon, else under the volume
    /// mount point, so that reaching it is always a `rename(2)`.
    public static let directoryName = ".fila-trash"

    /// Set on a trashed item by the job that renamed it, holding the canonical
    /// path it was renamed away from. Read back by Put Back; removed again once
    /// the item is home. Absent where it could not be set, and then the item
    /// can only be deleted for good or moved out by hand.
    public static let originAttribute = "wiki.qaq.fila.origin"

    public static func directory(under base: String) -> String {
        base == "/" ? "/" + directoryName : base + "/" + directoryName
    }
}
