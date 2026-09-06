import FilaProtocol
import Foundation

/// Selects the installed app's contents for an isolated installation fixture.
/// The caller creates a fresh destination and awaits the returned copy job.
public enum AppInstallFixture {
    public static func copyRequest(from bundle: URL, to destination: URL, link: DaemonLink) async throws -> JobRequest {
        // RootHide's .jbroot points at the live bootstrap, so removing it
        // after a whole-bundle copy hits the daemon's destruction guard.
        // PlugIns retains the real app's identity and shared container.
        // Exclude both here regardless of their type or link target.
        var sources: [String] = []
        var cursor: UInt64 = 0
        repeat {
            let page = try await link.list(directory: bundle.path, cursor: cursor)
            for entry in page.entries where entry.name != ".jbroot" && entry.name != "PlugIns" {
                sources.append(bundle.appendingPathComponent(entry.name).path)
            }
            cursor = page.cursor
        } while cursor != 0

        // This is one shallow selection, not a tree walk: FileJob still owns
        // recursive copying, metadata preservation and cancellation.
        return JobRequest(kind: .copy, sources: sources, destination: destination.path)
    }
}
