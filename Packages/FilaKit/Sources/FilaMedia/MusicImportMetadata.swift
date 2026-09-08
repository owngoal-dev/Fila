import AVFoundation
import Foundation

/// File tags and their MusicLibrary field names. Unknown tags remain in the
/// unchanged audio file; only understood fields are sent to the native API.
public struct MusicImportMetadata: Sendable {
    public var strings: [String: String] = [:]
    public var numbers: [String: Int64] = [:]
    public var artwork: Data?

    public static func read(from asset: AVAsset) async throws -> Self {
        try await read(items: asset.load(.metadata))
    }

    static func read(items: [AVMetadataItem]) async throws -> Self {
        var result = Self()
        for item in items {
            let identifier = item.identifier
            let text = try await item.load(.stringValue)
            let field: String? = switch identifier {
            case .iTunesMetadataAlbumArtist, .id3MetadataBand: "AlbumArtist"
            case .iTunesMetadataLyrics, .id3MetadataUnsynchronizedLyric: "Lyrics"
            case .iTunesMetadataComposer, .id3MetadataComposer: "Composer"
            case .iTunesMetadataUserGenre, .id3MetadataContentType: "Genre"
            case .iTunesMetadataUserComment, .id3MetadataComments: "Comment"
            case .iTunesMetadataCopyright, .id3MetadataCopyright: "Copyright"
            case .id3MetadataAlbumSortOrder: "SortAlbum"
            case .id3MetadataPerformerSortOrder: "SortArtist"
            case .id3MetadataTitleSortOrder: "SortTitle"
            default:
                switch item.commonKey {
                case .commonKeyTitle: "Title"
                case .commonKeyArtist: "Artist"
                case .commonKeyAlbumName: "Album"
                case .commonKeyCopyrights: "Copyright"
                default: ["itsk/sonm": "SortTitle", "itsk/soal": "SortAlbum", "itsk/soar": "SortArtist",
                          "itsk/soaa": "SortAlbumArtist", "itsk/soco": "SortComposer"][identifier?.rawValue ?? ""]
                }
            }
            if let field, let text, !text.isEmpty { result.strings[field] = text }
            if item.commonKey == .commonKeyArtwork, result.artwork == nil {
                result.artwork = try await item.load(.dataValue)
            }
            switch identifier {
            case .iTunesMetadataTrackNumber, .id3MetadataTrackNumber,
                 .iTunesMetadataDiscNumber, .id3MetadataPartOfASet:
                let isDisc = identifier == .iTunesMetadataDiscNumber || identifier == .id3MetadataPartOfASet
                let data = try await item.load(.dataValue)
                let pair = numberPair(text: text, data: data)
                if let number = pair.number { result.numbers[isDisc ? "DiscNumber" : "TrackNumber"] = number }
                if let total = pair.total { result.numbers[isDisc ? "DiscCount" : "TrackCount"] = total }
            case .iTunesMetadataDiscCompilation:
                if let number = try await item.load(.numberValue) {
                    result.numbers["Compilation"] = number.boolValue ? 1 : 0
                }
            case .iTunesMetadataReleaseDate, .id3MetadataYear, .id3MetadataRecordingTime, .id3MetadataReleaseTime:
                if let text {
                    if let year = Int64(text.prefix(4)), (1...9999).contains(year) { result.numbers["Year"] = year }
                    result.strings["ReleaseDate"] = text
                    if let date = releaseDate(text) {
                        result.numbers["ReleaseDateTime"] = Int64(date.timeIntervalSinceReferenceDate)
                    }
                }
            default: break
            }
        }
        return result
    }

    private static func releaseDate(_ text: String) -> Date? {
        if text.count == 10 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            formatter.isLenient = false
            // Date-only releases use UTC noon, matching MusicLibrary's storage.
            return formatter.date(from: text + " 12:00")
        }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }

    static func numberPair(text: String?, data: Data?) -> (number: Int64?, total: Int64?) {
        if let data, data.count >= 6 {
            let bytes = Array(data.prefix(6))
            let number = Int64(bytes[2]) << 8 | Int64(bytes[3])
            let total = Int64(bytes[4]) << 8 | Int64(bytes[5])
            return (number > 0 ? number : nil, total > 0 ? total : nil)
        }
        let parts = (text ?? "").split(separator: "/", omittingEmptySubsequences: false)
        func positive(_ index: Int) -> Int64? {
            guard parts.indices.contains(index), let number = Int64(parts[index].trimmingCharacters(in: .whitespaces)),
                  number > 0, number <= Int64(Int32.max) else { return nil }
            return number
        }
        return (positive(0), positive(1))
    }
}
