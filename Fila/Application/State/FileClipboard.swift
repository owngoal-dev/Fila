import FilaBackendKit
import FilaLog
import Foundation

extension Notification.Name {
    static let filaClipboardChanged = Notification.Name("wiki.qaq.fila.clipboard")
}

/// What Copy and Move put aside for Paste.
///
/// Deliberately not `UIPasteboard`: these are root-owned paths and server
/// locations that only this app can act on, and putting them on the system
/// pasteboard would hand every other app a list of them for nothing.
///
/// **Locations, not files.** An entry is a backend and a path under it —
/// the local root, or a saved share — and a clipboard holds a promise that
/// can break: the file can be renamed, moved or deleted between the Copy
/// and the Paste, by this app in another tab or by anything else with a
/// hand on that filesystem. Nothing is captured at Copy time to paper over
/// that — a stored size would only be a stale number to disagree with the
/// disk. The state of an entry is whatever its backend says right now,
/// which is why the one screen that shows it, `ClipboardViewController`,
/// asks the backend rather than reading a field here.
@MainActor
final class FileClipboard {
    static let shared = FileClipboard()

    private(set) var items: [FileLocation] = []
    /// A move rather than a copy — the items are gone from where they were
    /// once the paste lands.
    private(set) var isCut = false
    /// When Copy or Move was tapped. Shown by the inspector, because "taken
    /// twenty minutes ago" is the fact that explains an entry that has since
    /// stopped resolving.
    private(set) var takenAt: Date?

    struct Paste {
        let id = UUID()
        fileprivate let revision: UUID
        let items: [FileLocation]
        let isCut: Bool
    }

    private var revision = UUID()
    private var activePaste: Paste?

    var isEmpty: Bool {
        items.isEmpty
    }

    var isPasting: Bool {
        activePaste != nil
    }

    /// The absolute paths of the local entries, for the screens that still
    /// speak in paths. Remote entries have none.
    var paths: [String] {
        let local = FileSession.shared.local
        return items.compactMap { $0.backend == local.id ? local.absolutePath($0.path) : nil }
    }

    private init() {}

    /// Local paths, filed under the local backend. A path outside its root
    /// — nothing on a device, only a Mac development loop can make one —
    /// is dropped with a line in the log rather than held as a promise
    /// nothing can keep.
    func take(_ paths: [String], cut: Bool) {
        let local = FileSession.shared.local
        let located = paths.compactMap { path -> FileLocation? in
            guard let servicePath = local.servicePath(forAbsolute: path) else {
                FilaLog.warning("clipboard: \(path) is outside the local root and was not taken")
                return nil
            }
            return FileLocation(backend: local.id, path: servicePath)
        }
        take(located, cut: cut)
    }

    func take(_ items: [FileLocation], cut: Bool) {
        guard !items.isEmpty else { return }
        // A paste is explained by what was taken and when. The clipboard holds
        // a promise that can break between the two, and the log is where the
        // gap becomes visible.
        FilaLog.info("clipboard \(cut ? "cut" : "copied") \(items.count) item(s) on \(Set(items.map(\.backend.rawValue)).sorted().joined(separator: ", "))")
        revision = UUID()
        self.items = items
        isCut = cut
        takenAt = Date()
        NotificationCenter.default.post(name: .filaClipboardChanged, object: self)
    }

    /// Drops one entry. Emptying the clipboard this way is the same as clearing
    /// it: a held operation with nothing left to apply it to is not a state
    /// worth having.
    func remove(_ item: FileLocation) {
        items.removeAll { $0 == item }
        if items.isEmpty {
            clear()
        } else {
            NotificationCenter.default.post(name: .filaClipboardChanged, object: self)
        }
    }

    func clear() {
        revision = UUID()
        items = []
        isCut = false
        takenAt = nil
        NotificationCenter.default.post(name: .filaClipboardChanged, object: self)
    }

    /// Reserve the current selection before starting any asynchronous work.
    /// A later Copy can replace the clipboard without an old completion clearing it.
    func beginPaste() -> Paste? {
        guard !isEmpty, !isPasting else { return nil }
        let paste = Paste(revision: revision, items: items, isCut: isCut)
        activePaste = paste
        NotificationCenter.default.post(name: .filaClipboardChanged, object: self)
        return paste
    }

    /// Copy remains reusable. Only a successful move consumes its selection;
    /// a failed or partial batch does not say which individual roots moved.
    func finishPaste(_ paste: Paste, succeeded: Bool) {
        guard let active = activePaste, active.id == paste.id else { return }
        activePaste = nil
        if revision == paste.revision, paste.isCut, succeeded {
            clear()
            return
        }
        NotificationCenter.default.post(name: .filaClipboardChanged, object: self)
    }
}
