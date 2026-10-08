import FilaFormats
import FilaProtocol
import Foundation

/// What a search keeps besides a name: a kind, a size and an age, combined.
/// Each is one choice from a short list rather than a typed value, so the
/// screen's menu is the whole form.
struct FileSearchFilter: Hashable {
    enum Kind: CaseIterable {
        case any
        case folders
        case files
        case images
        case videos
        case audio
        case text
        case archives
        case documents
    }

    /// Bands rather than a number to type: each lower bound is inclusive and
    /// each upper bound exclusive, in the decimal units `ByteCountFormatter`
    /// shows. Only a regular file has a size worth comparing — a folder's is
    /// its own entry's, and a link's is its target's path — so any band
    /// leaves folders and links out.
    enum Size: CaseIterable {
        case any
        case empty
        case tiny
        case small
        case medium
        case large
        case huge

        var bounds: (lower: Int64, upper: Int64?)? {
            switch self {
            case .any: nil
            case .empty: (0, 1)
            case .tiny: (0, 10_000)
            case .small: (10_000, 1_000_000)
            case .medium: (1_000_000, 100_000_000)
            case .large: (100_000_000, 1_000_000_000)
            case .huge: (1_000_000_000, nil)
            }
        }
    }

    enum Age: CaseIterable {
        case any
        case today
        case week
        case month
        case year

        /// The earliest modification date that still matches, as of `now`.
        func cutoff(from now: Date) -> Date? {
            let calendar = Calendar.current
            return switch self {
            case .any: nil
            case .today: calendar.startOfDay(for: now)
            case .week: calendar.date(byAdding: .day, value: -7, to: now)
            case .month: calendar.date(byAdding: .month, value: -1, to: now)
            case .year: calendar.date(byAdding: .year, value: -1, to: now)
            }
        }
    }

    var kind = Kind.any
    var size = Size.any
    var age = Age.any

    var isActive: Bool {
        self != FileSearchFilter()
    }
}

/// A name and a filter, decided for one search. The age's cutoff is taken
/// once, here, so every row of one search is held to the same moment.
@MainActor
final class FileSearchMatcher {
    let needle: String
    let filter: FileSearchFilter
    private let cutoff: Double?
    /// `FileFormat.detect(name:)` by extension: a walk of `/` asks about
    /// hundreds of thousands of names and a few hundred extensions, and an
    /// unknown one costs a `UTType` lookup.
    private var formats: [String: FileFormat?] = [:]

    init(needle: String, filter: FileSearchFilter, now: Date = Date()) {
        self.needle = needle
        self.filter = filter
        cutoff = filter.age.cutoff(from: now)?.timeIntervalSince1970
    }

    /// Nothing typed. Filters narrow a name search and never start one:
    /// a filter alone would list a whole subtree.
    var isEmpty: Bool {
        needle.isEmpty
    }

    /// Whether every name this matches is also matched by `other`, so the
    /// complete results of `other` already hold all of this one's. The
    /// cutoffs need no comparing: with the same filter, a later matcher's
    /// cutoff is the same or later, which only narrows it further.
    func narrows(_ other: FileSearchMatcher) -> Bool {
        filter == other.filter && (other.needle.isEmpty || Self.contains(needle, other.needle))
    }

    func matches(_ node: FileNode) -> Bool {
        guard needle.isEmpty || Self.contains(node.name, needle) else { return false }
        if let bounds = filter.size.bounds {
            guard node.kind == .regular, node.size >= bounds.lower else { return false }
            if let upper = bounds.upper, node.size >= upper {
                return false
            }
        }
        if let cutoff, node.modified < cutoff {
            return false
        }
        return matchesKind(node)
    }

    /// The comparison the row highlight makes, so a row is listed exactly
    /// when part of its name is tinted.
    private static func contains(_ name: String, _ needle: String) -> Bool {
        name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func matchesKind(_ node: FileNode) -> Bool {
        switch filter.kind {
        case .any: return true
        case .folders: return node.isNavigable
        case .files: return !node.isNavigable
        default: break
        }
        guard !node.isNavigable else { return false }
        let format = format(of: node.name)
        return switch filter.kind {
        case .images: format == .image
        case .videos: format == .video
        case .audio: format == .audio
        case .text: format == .text
        case .archives: format == .archive
        case .documents: format == .document || format == .pdf
        case .any, .folders, .files: true
        }
    }

    private func format(of name: String) -> FileFormat? {
        let key = (name as NSString).pathExtension.lowercased()
        if let known = formats[key] {
            return known
        }
        let format = FileFormat.detect(name: name)
        formats[key] = format
        return format
    }
}
