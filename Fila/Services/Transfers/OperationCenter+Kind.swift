import Foundation

extension OperationCenter.Kind {
    /// Present tense, for the row while it runs.
    var runningTitle: String {
        switch self {
        case .copy: String(localized: "Copying…")
        case .move: String(localized: "Moving…")
        case .trash: String(localized: "Moving to Trash…")
        case .delete: String(localized: "Deleting…")
        case .compress: String(localized: "Compressing…")
        case .extract: String(localized: "Extracting…")
        case .rename: String(localized: "Renaming…")
        case .create: String(localized: "Creating…")
        case .attributes: String(localized: "Changing Attributes…")
        case .download: String(localized: "Downloading…")
        }
    }

    /// Past tense, for the toast that says it is over.
    var completionTitle: String {
        switch self {
        case .copy: String(localized: "Copied")
        case .move: String(localized: "Moved")
        case .trash: String(localized: "Moved to Trash")
        case .delete: String(localized: "Deleted")
        case .compress: String(localized: "Compressed")
        case .extract: String(localized: "Extracted")
        case .rename: String(localized: "Renamed")
        case .create: String(localized: "Created")
        case .attributes: String(localized: "Attributes Changed")
        case .download: String(localized: "Downloaded")
        }
    }

    /// Every one of these is a symbol the app already ships, which is the point:
    /// a symbol added after iOS 15 draws nothing at all — no warning from the
    /// compiler, no error at runtime, just a gap where the icon was. Reusing
    /// what the menus already use is how that stays impossible.
    var symbol: String {
        switch self {
        case .copy: "doc.on.doc"
        case .move: "scissors"
        case .trash: "trash"
        case .delete: "trash"
        case .compress: "doc.zipper"
        case .extract: "arrow.down.to.line"
        case .rename: "pencil"
        case .create: "plus"
        case .attributes: "doc.badge.gearshape"
        case .download: "arrow.down.circle"
        }
    }
}
