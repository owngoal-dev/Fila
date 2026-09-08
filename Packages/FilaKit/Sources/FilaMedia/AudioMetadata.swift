import AVFoundation
import Foundation

/// Music tags decoded by AVFoundation over the existing descriptor-backed asset.
/// No second path open, temporary copy, or daemon content request is involved.
public struct AudioMetadata {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var composer: String?
    public var genre: String?
    public var artwork: Data?
    public var trackNumber: Int?
    public var trackCount: Int?
    public var discNumber: Int?
    public var discCount: Int?

    public static func load(from asset: AVAsset) async -> AudioMetadata {
        var items = Array(((try? await asset.load(.commonMetadata)) ?? []).prefix(256))
        for format in ((try? await asset.load(.availableMetadataFormats)) ?? []).prefix(8) {
            guard items.count < 256 else { break }
            guard !Task.isCancelled else { return AudioMetadata() }
            items += ((try? await asset.loadMetadata(for: format)) ?? []).prefix(256 - items.count)
        }
        return await decode(items)
    }

    static func decode(_ items: [AVMetadataItem]) async -> AudioMetadata {
        var result = AudioMetadata()
        for item in items.prefix(256) {
            guard !Task.isCancelled else { break }
            guard let identifier = item.identifier else { continue }
            if [.commonIdentifierArtwork, .iTunesMetadataCoverArt, .id3MetadataAttachedPicture,
                .quickTimeMetadataArtwork].contains(identifier) {
                if result.artwork == nil, let data = try? await item.load(.dataValue), !data.isEmpty, data.count <= 16 * 1_024 * 1_024 {
                    result.artwork = data
                }
                continue
            }
            if identifier == .iTunesMetadataTrackNumber || identifier == .iTunesMetadataDiscNumber {
                var pair: (number: Int?, count: Int?) = (nil, nil)
                if let data = try? await item.load(.dataValue), let decoded = numberPair(data: data) {
                    pair = decoded
                } else if let text = try? await item.load(.stringValue) {
                    pair = numberPair(text: text)
                }
                if identifier == .iTunesMetadataTrackNumber {
                    if result.trackNumber == nil { result.trackNumber = pair.number }
                    if result.trackCount == nil { result.trackCount = pair.count }
                } else {
                    if result.discNumber == nil { result.discNumber = pair.number }
                    if result.discCount == nil { result.discCount = pair.count }
                }
                continue
            }
            switch identifier {
            case .commonIdentifierTitle, .iTunesMetadataSongName, .id3MetadataTitleDescription, .quickTimeMetadataTitle,
                 .commonIdentifierArtist, .iTunesMetadataArtist, .id3MetadataLeadPerformer, .quickTimeMetadataArtist,
                 .commonIdentifierAlbumName, .iTunesMetadataAlbum, .id3MetadataAlbumTitle, .quickTimeMetadataAlbum,
                 .iTunesMetadataAlbumArtist, .id3MetadataBand,
                 .iTunesMetadataComposer, .id3MetadataComposer, .quickTimeMetadataComposer, .quickTimeUserDataComposer,
                 .iTunesMetadataUserGenre, .id3MetadataContentType, .quickTimeMetadataGenre, .quickTimeUserDataGenre,
                 .id3MetadataTrackNumber, .id3MetadataPartOfASet: break
            default: continue
            }
            guard let raw = try? await item.load(.stringValue) else { continue }
            let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_192))
            guard !text.isEmpty else { continue }
            switch identifier {
            case .commonIdentifierTitle, .iTunesMetadataSongName, .id3MetadataTitleDescription, .quickTimeMetadataTitle:
                if result.title == nil { result.title = text }
            case .commonIdentifierArtist, .iTunesMetadataArtist, .id3MetadataLeadPerformer, .quickTimeMetadataArtist:
                if result.artist == nil { result.artist = text }
            case .commonIdentifierAlbumName, .iTunesMetadataAlbum, .id3MetadataAlbumTitle, .quickTimeMetadataAlbum:
                if result.album == nil { result.album = text }
            case .iTunesMetadataAlbumArtist, .id3MetadataBand:
                if result.albumArtist == nil { result.albumArtist = text }
            case .iTunesMetadataComposer, .id3MetadataComposer, .quickTimeMetadataComposer, .quickTimeUserDataComposer:
                if result.composer == nil { result.composer = text }
            case .iTunesMetadataUserGenre, .id3MetadataContentType, .quickTimeMetadataGenre, .quickTimeUserDataGenre:
                if result.genre == nil { result.genre = text }
            case .id3MetadataTrackNumber:
                let pair = numberPair(text: text)
                if result.trackNumber == nil { result.trackNumber = pair.number }
                if result.trackCount == nil { result.trackCount = pair.count }
            case .id3MetadataPartOfASet:
                let pair = numberPair(text: text)
                if result.discNumber == nil { result.discNumber = pair.number }
                if result.discCount == nil { result.discCount = pair.count }
            default:
                break
            }
        }
        return result
    }

    /// iTunes trkn/disk atoms contain reserved, number and total UInt16 fields.
    static func numberPair(data: Data) -> (number: Int?, count: Int?)? {
        guard data.count >= 6 else { return nil }
        let bytes = Array(data.prefix(6))
        let number = Int(bytes[2]) << 8 | Int(bytes[3])
        let count = Int(bytes[4]) << 8 | Int(bytes[5])
        return (number > 0 ? number : nil, count > 0 ? count : nil)
    }

    static func numberPair(text: String) -> (number: Int?, count: Int?) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        func positive(_ value: Substring?) -> Int? {
            guard let value, let number = Int(value.trimmingCharacters(in: .whitespaces)), number > 0 else { return nil }
            return number
        }
        return (positive(parts.first), parts.count == 2 ? positive(parts.last) : nil)
    }
}
