import AVFoundation
@testable import FilaMedia
import Foundation
import Testing

struct AudioMetadataTests {
    @Test func id3TagsKeepUsefulFieldsAndSkipEmptyFallbacks() async {
        func tag(_ identifier: AVMetadataIdentifier, _ text: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = text as NSString
            return item
        }
        let metadata = await AudioMetadata.decode([
            tag(.commonIdentifierTitle, "  "), tag(.id3MetadataTitleDescription, " Track "),
            tag(.id3MetadataLeadPerformer, "Artist"), tag(.id3MetadataAlbumTitle, "Album"),
            tag(.id3MetadataComposer, "Composer"), tag(.id3MetadataBand, "Album Artist"),
            tag(.id3MetadataTrackNumber, "3/12"), tag(.id3MetadataPartOfASet, "2/4"),
        ])
        #expect(metadata.title == "Track")
        #expect(metadata.artist == "Artist")
        #expect(metadata.album == "Album")
        #expect(metadata.composer == "Composer")
        #expect(metadata.albumArtist == "Album Artist")
        #expect(metadata.trackNumber == 3 && metadata.trackCount == 12)
        #expect(metadata.discNumber == 2 && metadata.discCount == 4)
    }

    @Test func trackAtomsAreBigEndianAndTruncationDoesNotInventNumbers() {
        let pair = AudioMetadata.numberPair(data: Data([0, 0, 1, 2, 1, 44, 0, 0]))
        #expect(pair?.number == 258 && pair?.count == 300)
        #expect(AudioMetadata.numberPair(data: Data([0, 0, 2])) == nil)
        let invalid = AudioMetadata.numberPair(text: "-3/not a number")
        #expect(invalid.number == nil && invalid.count == nil)
    }
}
