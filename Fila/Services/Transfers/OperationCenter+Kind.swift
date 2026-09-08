import Foundation

extension OperationCenter.Kind {
    /// Present tense, for the row while it runs.
    var runningTitle: String {
        switch self {
        case .copy: return String(localized: "Copying…")
        case .move: return String(localized: "Moving…")
        case .trash: return String(localized: "Moving to Trash…")
        case .delete: return String(localized: "Deleting…")
        case .compress: return String(localized: "Compressing…")
        case .extract: return String(localized: "Extracting…")
        case .rename: return String(localized: "Renaming…")
        case .create: return String(localized: "Creating…")
        case .attributes: return String(localized: "Changing Attributes…")
        case .download: return String(localized: "Downloading…")
        }
    }

    /// Past tense, for the toast that says it is over.
    var completionTitle: String {
        switch self {
        case .copy: return String(localized: "Copied")
        case .move: return String(localized: "Moved")
        case .trash: return String(localized: "Moved to Trash")
        case .delete: return String(localized: "Deleted")
        case .compress: return String(localized: "Compressed")
        case .extract: return String(localized: "Extracted")
        case .rename: return String(localized: "Renamed")
        case .create: return String(localized: "Created")
        case .attributes: return String(localized: "Attributes Changed")
        case .download: return String(localized: "Downloaded")
        }
    }

    /// Every one of these is a symbol the app already ships, which is the point:
    /// a symbol added after iOS 15 draws nothing at all — no warning from the
    /// compiler, no error at runtime, just a gap where the icon was. Reusing
    /// what the menus already use is how that stays impossible.
    var symbol: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .move: return "scissors"
        case .trash: return "trash"
        case .delete: return "trash"
        case .compress: return "doc.zipper"
        case .extract: return "arrow.down.to.line"
        case .rename: return "pencil"
        case .create: return "plus"
        case .attributes: return "doc.badge.gearshape"
        case .download: return "arrow.down.circle"
        }
    }
}
