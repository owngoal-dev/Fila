import AVFoundation
@testable import FilaMedia
import Foundation
import Testing

@Suite("Music import metadata")
struct MusicImportMetadataTests {
    private func item(_ identifier: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        return item
    }

    @Test("Album, artist, lyrics and embedded artwork survive extraction")
    func textAndArtwork() async throws {
        let cover = Data([1, 2, 3])
        let metadata = try await MusicImportMetadata.read(items: [
            item(.iTunesMetadataSongName, "歌曲" as NSString),
            item(.iTunesMetadataAlbum, "专辑" as NSString),
            item(.iTunesMetadataArtist, "歌手" as NSString),
            item(.iTunesMetadataAlbumArtist, "Various Artists" as NSString),
            item(.iTunesMetadataLyrics, "[00:01.00]first\n[00:02.00]second" as NSString),
            item(.iTunesMetadataComposer, "Composer" as NSString),
            item(.iTunesMetadataUserGenre, "Soundtrack" as NSString),
            item(.iTunesMetadataCoverArt, cover as NSData),
            item(.iTunesMetadataCoverArt, Data([4]) as NSData),
        ])
        #expect(metadata.strings["Title"] == "歌曲")
        #expect(metadata.strings["Album"] == "专辑")
        #expect(metadata.strings["Artist"] == "歌手")
        #expect(metadata.strings["AlbumArtist"] == "Various Artists")
        #expect(metadata.strings["Lyrics"] == "[00:01.00]first\n[00:02.00]second")
        #expect(metadata.strings["Composer"] == "Composer")
        #expect(metadata.strings["Genre"] == "Soundtrack")
        #expect(metadata.artwork == cover)
    }

    @Test("M4A binary track and disc tags preserve totals")
    func numberTags() async throws {
        let metadata = try await MusicImportMetadata.read(items: [
            item(.iTunesMetadataTrackNumber, Data([0,0,0,4,0,7,0,0]) as NSData),
            item(.iTunesMetadataDiscNumber, Data([0,0,0,1,0,2]) as NSData),
            item(.iTunesMetadataReleaseDate, "2023-06-20" as NSString),
        ])
        #expect(metadata.numbers["TrackNumber"] == 4)
        #expect(metadata.numbers["TrackCount"] == 7)
        #expect(metadata.numbers["DiscNumber"] == 1)
        #expect(metadata.numbers["DiscCount"] == 2)
        #expect(metadata.numbers["Year"] == 2023)
        #expect(metadata.numbers["ReleaseDateTime"] == 708_955_200)
        #expect(metadata.strings["ReleaseDate"] == "2023-06-20")
    }

    @Test("ID3 text numbers and invalid values are handled without inventing tags")
    func textNumbers() async throws {
        let metadata = try await MusicImportMetadata.read(items: [
            item(.id3MetadataTrackNumber, " 4 / 7 " as NSString),
            item(.id3MetadataPartOfASet, "-1/invalid" as NSString),
            item(.id3MetadataBand, "Album Artist" as NSString),
        ])
        #expect(metadata.numbers["TrackNumber"] == 4)
        #expect(metadata.numbers["TrackCount"] == 7)
        #expect(metadata.numbers["DiscNumber"] == nil)
        #expect(metadata.numbers["DiscCount"] == nil)
        #expect(metadata.strings["AlbumArtist"] == "Album Artist")
        #expect(MusicImportMetadata.numberPair(text: nil, data: Data([0])).number == nil)
    }
}
