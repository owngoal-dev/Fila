import FilaBackendKit
import FilaProtocol
import Foundation

/// How a folder's rows are filtered and ordered: a value, so a sort can run
/// wherever it is cheapest — off the main thread for a load's applies — with
/// the preferences it was asked under.
struct FileArrangement: Sendable {
    var showsHidden: Bool
    var sortKey: FileSortKey
    var ascending: Bool

    func arrange(_ nodes: [FileNode]) -> [FileNode] {
        // Deduplicated by name: pages are read from a directory that is live,
        // and one name arriving twice would put two rows with the same identity
        // into the snapshot, which is a crash rather than a glitch.
        var seen = Set<String>()
        var items = nodes.filter { seen.insert($0.name).inserted }
        if !showsHidden {
            items.removeAll(where: \.isHidden)
        }
        return items.sorted(by: precedes)
    }

    /// Directories first regardless of direction — reversing that puts the way
    /// out of a folder at the bottom of a hundred thousand files.
    private func precedes(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        if lhs.isNavigable != rhs.isNavigable {
            return lhs.isNavigable
        }
        let order: ComparisonResult = switch sortKey {
        case .name: lhs.name.localizedStandardCompare(rhs.name)
        case .date: compare(lhs.modified, rhs.modified)
        case .size: compare(lhs.size, rhs.size)
        case .kind: FilePresentation.sortKind(for: lhs).compare(FilePresentation.sortKind(for: rhs))
        }
        guard order != .orderedSame else {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return ascending ? order == .orderedAscending : order == .orderedDescending
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }
}
