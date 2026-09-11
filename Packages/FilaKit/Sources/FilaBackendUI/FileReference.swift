#if canImport(UIKit)
import FilaBackendKit
import UIKit
import UniformTypeIdentifiers

/// A file or folder anywhere Fila reaches: a path on this device, or a
/// location on a share. Local items are named by path rather than as the
/// local backend's locations because a sandboxed local root (Documents) does
/// not contain the Inbox or the app's workspace.
///
/// It is what a drag carries between Fila's own screens — as the drag item's
/// local object, which only this process can read; a drop from another app
/// has none and brings files — and where a paste, a drop or an import is
/// delivered. Every file screen proposes a drop with the helpers here and
/// hands it to the shell (`BackendShell.drop`), so a folder, a share and the
/// music library take the same drag the same way.
public enum FileReference: Sendable, Hashable {
    /// An absolute path on this device.
    case local(String)
    /// A file or folder on a share.
    case remote(FileLocation)

    public var name: String {
        switch self {
        case let .local(path): (path as NSString).lastPathComponent
        case let .remote(location): location.path.name ?? location.path.description
        }
    }

    /// Whether dropping this into `folder` would change nothing: it is the
    /// folder, or already in it.
    public func isAlreadyIn(_ folder: FileReference) -> Bool {
        switch (self, folder) {
        case let (.local(path), .local(directory)):
            path == directory || (path as NSString).deletingLastPathComponent == directory
        case let (.remote(location), .remote(directory)):
            location == directory || (location.backend == directory.backend && location.path.parent == directory.path)
        default:
            false
        }
    }

    // MARK: - Dragging

    /// A drag item for this file. `provider` is what other apps are offered;
    /// Fila's own screens read the local object.
    @MainActor
    public func dragItem(_ provider: NSItemProvider = NSItemProvider()) -> UIDragItem {
        provider.suggestedName = name
        let item = UIDragItem(itemProvider: provider)
        item.localObject = self
        return item
    }

    /// The items of a drop that were dragged inside Fila.
    @MainActor
    public static func dragged(_ items: [UIDragItem]) -> [FileReference] {
        items.compactMap { $0.localObject as? FileReference }
    }

    /// Whether this is one of `types`, by its extension. Anything is `.data`,
    /// a folder included.
    public func isFile(of types: [UTType]) -> Bool {
        guard !types.contains(.data) else { return true }
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return false }
        return types.contains { type.conforms(to: $0) }
    }

    /// The badge a drop into `folder` earns: forbidden when it brings nothing
    /// that would land there — only files already in it, or no files at all —
    /// so the badge never promises a copy the drop then declines. `types`
    /// narrows what counts (the music library takes the formats it imports).
    @MainActor
    public static func proposal(for session: UIDropSession, into folder: FileReference?, types: [UTType] = [.data]) -> UIDropOperation {
        let accepted = session.items.contains { item in
            if let file = item.localObject as? FileReference {
                if let folder, file.isAlreadyIn(folder) { return false }
                return file.isFile(of: types)
            }
            return item.itemProvider.fileTypeIdentifier(conformingTo: types) != nil
        }
        return accepted ? .copy : .forbidden
    }
}

public extension NSItemProvider {
    /// The first registered type that is one of `types` and is a file: what
    /// a drop's badge promises and what the import loads. A link is not a
    /// file, and is refused rather than saved as a `.webloc`.
    func fileTypeIdentifier(conformingTo types: [UTType]) -> String? {
        registeredTypeIdentifiers.first {
            guard let registered = UTType($0), !registered.conforms(to: .url) else { return false }
            return types.contains { registered.conforms(to: $0) }
        }
    }
}
#endif
