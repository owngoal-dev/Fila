#if canImport(UIKit)
import FilaBackendKit
import UIKit

/// Application artwork as the applications module renders it, for every
/// row that shows an app: the module's own list, the browser's `.app`
/// folders and containers, the sidebar's decorated recents.
@MainActor
public protocol ApplicationArtwork: AnyObject {
    /// What a row shows for an app with no artwork, and while artwork loads.
    var placeholder: UIImage? { get }
    /// Artwork already fetched, or nil. Cells paint from here on the scroll
    /// tick and ask `icon(for:)` for whatever is missing.
    func cachedIcon(for identifier: String?) -> UIImage?
    /// Artwork, fetched off the main actor when it is not cached yet.
    func icon(for identifier: String?) async -> UIImage?
}


/// What the shell lends to module screens: a browser for a file location,
/// a picker for a file, and the app's feedback chrome. Set once by the app
/// before any screen exists; a module screen never builds these itself.
@MainActor
public protocol BackendShell: AnyObject {
    /// A file browser at `location`, to push into the caller's stack.
    func browser(for location: BackendLocation) -> UIViewController?
    /// A file picker over the local filesystem, limited to `fileTypes`
    /// (extensions, lowercased; nil for any file), calling `chosen` with the
    /// picked file. Presented by the caller.
    func filePicker(fileTypes: Set<String>?, chosen: @escaping (URL) -> Void) -> UIViewController
    /// A destination picker for saving `fileName`, calling `chosen` with
    /// the full target. Presented by the caller.
    func saveDestinationPicker(fileName: String, chosen: @escaping (URL) -> Void) -> UIViewController
    /// Presents `controller` as a sheet from `presenter`, the app's way.
    func presentSheet(_ controller: UIViewController, from presenter: UIViewController)
    /// A copy of the file at `path` in a workspace the caller removes.
    func stage(_ path: String) async throws -> URL
    /// A copy job of `source` into `directory`, run through the app's
    /// operation centre and awaited to its verdict; a failure throws it.
    func copy(_ source: URL, into directory: String, subtitle: String) async throws
    /// A permanent delete job for `path`, awaited; a missing path is not a
    /// failure.
    func delete(_ path: String, subtitle: String) async throws
    /// The transient success line.
    func toast(_ text: String)
    /// An error card with a title, a reason and Close.
    func alert(title: String, message: String)
    /// The permanent-deletion card, under the destructive accent.
    func confirmPermanentDeletion(
        from presenter: UIViewController,
        title: String,
        message: String,
        confirmTitle: String,
        confirmed: @escaping () -> Void
    )
    /// The wording for an error, as the app phrases failures.
    func failureText(for error: Error) -> String
    /// A fresh, app-owned directory in the process workspace, for a
    /// snapshot downloaded from a remote backend. The caller removes it
    /// when the viewer lets go; startup sweeps what a crash left.
    func makeWorkspace() async throws -> URL
    /// The app's icon for a file of that name, or a folder.
    func fileIcon(named name: String, isDirectory: Bool) -> UIImage?
    /// The app's artwork for a backend's root — the same picture its
    /// sidebar row shows — for the first crumb of the root's screens.
    func rootArtwork(for root: BackendRoot) -> UIImage?
    /// The delayed progress card for work that may take a while: shown
    /// only once it has, updated through the handle, dismissed by it.
    func progressCard(title: String, message: String, from presenter: UIViewController) -> any BackendProgressCard
    /// The app's viewer for a local file, pushed into `presenter`'s stack:
    /// a snapshot of a remote file gets the same reader a local one does.
    /// `released` runs once the viewer is gone, so its workspace can go.
    func preview(_ file: URL, title: String, from presenter: UIViewController, released: @escaping () -> Void)
    /// Shows the screen a module routes for `location` in the current
    /// tab, the way the sidebar's rows do.
    func open(_ location: BackendLocation)

    /// The app's clipboard as a module screen sees it: nil while empty.
    var clipboard: BackendClipboardSummary? { get }
    /// Puts `items` on the app's clipboard, replacing what was there.
    func takeToClipboard(_ items: [FileLocation], cut: Bool)
    /// Pastes the clipboard into `destination` through the app's operation
    /// centre, asking `presenter` about replacements and reporting to it.
    func paste(into destination: FileLocation, from presenter: UIViewController)
}

/// What a module screen needs to offer Paste: how many items wait, whether
/// they move or copy, and whether a paste is already under way.
public struct BackendClipboardSummary: Equatable, Sendable {
    public let count: Int
    public let isCut: Bool
    public let isPasting: Bool

    public init(count: Int, isCut: Bool, isPasting: Bool) {
        self.count = count
        self.isCut = isCut
        self.isPasting = isPasting
    }
}

/// A progress card the shell lent: what the caller can do with it.
@MainActor
public protocol BackendProgressCard: AnyObject {
    func update(message: String)
    func dismiss()
}

public extension UITableView {
    /// Reloads without the flash of an unanimated reload.
    func reloadWithAnimation() {
        UIView.transition(with: self, duration: 0.2, options: .transitionCrossDissolve) {
            self.reloadData()
        }
    }
}

public enum BackendScreens {
    /// The shell every module screen borrows from. The app assigns it at
    /// launch; a nil shell means a screen was made before the app was up,
    /// which is a bug, not a state to handle.
    public static var shell: (any BackendShell)?
}
#endif
