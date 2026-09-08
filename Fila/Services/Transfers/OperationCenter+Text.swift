import Foundation

// MARK: - Text

/// What an operation is called, for the two audiences that need different
/// answers: the row a person reads, and the log line grep reads.
@MainActor
extension OperationCenter {
    /// The same thing for a log line: real paths, never a translated count.
    ///
    /// Capped, because a record is truncated at
    /// `FilaLogRing.maximumMessageByteCount` and a line that loses its tail
    /// silently is worse than one that says how much it left out.
    static func describeForLog(_ paths: [String], destination: String? = nil) -> String {
        var line = paths.prefix(4).joined(separator: ", ")
        if paths.count > 4 {
            line += " +\(paths.count - 4) more"
        }
        return line + (destination.map { " → " + $0 } ?? "")
    }

    static func describe(_ paths: [String], destination: String? = nil) -> String {
        let what = paths.count == 1
            ? (paths[0] as NSString).lastPathComponent
            : String(localized: "\(paths.count) items")
        guard let destination else { return what }
        return what + " → " + destination
    }
}
