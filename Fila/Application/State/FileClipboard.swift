import FilaLog
import Foundation

extension Notification.Name {
    static let filaClipboardChanged = Notification.Name("wiki.qaq.fila.clipboard")
}

/// What Copy and Move put aside for Paste.
///
/// Deliberately not `UIPasteboard`: these are root-owned paths that only this
/// app can act on, and putting them on the system pasteboard would hand every
/// other app a list of them for nothing.
///
/// **Paths, not files.** A clipboard here holds a promise that can break: the
/// file can be renamed, moved or deleted between the Copy and the Paste, by this
/// app in another tab or by anything else running on the device. Nothing is
/// captured at Copy time to paper over that — a stored size would only be a
/// stale number to disagree with the disk. The state of an entry is whatever
/// `statPath` says right now, which is why the one screen that shows it,
/// `ClipboardViewController`, asks the daemon rather than reading a field here.
@MainActor
final class FileClipboard {
    static let shared = FileClipboard()

    private(set) var paths: [String] = []
    /// A move rather than a copy — the paths are gone from where they were once
    /// the paste lands.
    private(set) var isCut = false
    /// When Copy or Move was tapped. Shown by the inspector, because "taken
    /// twenty minutes ago" is the fact that explains an entry that has since
    /// stopped resolving.
    private(set) var takenAt: Date?

    struct Paste {
        let id = UUID()
        fileprivate let revision: UUID
        let paths: [String]
        let isCut: Bool
    }

    private var revision = UUID()
    private var activePaste: Paste?

    var isEmpty: Bool {
        paths.isEmpty
    }

    var isPasting: Bool {
        activePaste != nil
    }

    private init() {}

    func take(_ paths: [String], cut: Bool) {
        // A paste is explained by what was taken and when. The clipboard holds
        // a promise that can break between the two, and the log is where the
        // gap becomes visible.
        FilaLog.info("clipboard \(cut ? "cut" : "copied") \(paths.count) item(s)")
        revision = UUID()
        self.paths = paths
        isCut = cut
        takenAt = Date()
        NotificationCenter.default.post(name: .filaClipboardChanged, object: self)
    }

    /// Drops one entry. Emptying the clipboard this way is the same as clearing
    /// it: a held operation with nothing left to apply it to is not a state
    /// worth having.
    func remove(_ path: String) {
        paths.removeAll { $0 == path }
        if paths.isEmpty {
            clear()
        } else {
            NotificationCenter.default.post(name: .filaClipboardChanged, object: self)
        }
    }

    func clear() {
        revision = UUID()
        paths = []
        isCut = false
        takenAt = nil
        NotificationCenter.default.post(name: .filaClipboardChanged, object: self)
    }

    /// Reserve the current selection before starting any asynchronous work.
    /// A later Copy can replace the clipboard without an old completion clearing it.
    func beginPaste() -> Paste? {
        guard !isEmpty, !isPasting else { return nil }
        let paste = Paste(revision: revision, paths: paths, isCut: isCut)
        activePaste = paste
        NotificationCenter.default.post(name: .filaClipboardChanged, object: self)
        return paste
    }

    /// Copy remains reusable. Only a successful move consumes its selection;
    /// a failed batch does not say which individual roots, if any, moved.
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
