import Foundation

struct MusicLibraryTrack: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
}
