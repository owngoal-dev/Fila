import Foundation

public struct MusicLibraryTrack: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval

    public init(id: Int64, title: String, artist: String, album: String, duration: TimeInterval) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// The file name a song is exported under: its title, made safe as a path
/// component, with the source file's own extension.
public enum MusicExportNaming {
    public static func name(title: String, sourcePath: String, untitled: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:")))
            .filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        var stem = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? untitled : cleaned
        while stem.utf8.count > 180 { stem.removeLast() }
        let suffix = (sourcePath as NSString).pathExtension
        return suffix.isEmpty ? stem : stem + "." + suffix
    }
}
