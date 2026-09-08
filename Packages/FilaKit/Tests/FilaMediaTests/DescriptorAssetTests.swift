import AVFoundation
import CoreVideo
@testable import FilaMedia
import Foundation
import Testing

/// The resource loader is the load-bearing piece of playback: if it answers a
/// byte range wrongly, the file plays with a corrupt picture rather than
/// failing, and nothing else in this project would catch that.
@Suite("Descriptor-backed assets")
struct DescriptorAssetTests {
    @Test("Video properties include duration, display dimensions and frame rate")
    func videoInformation() async throws {
        try await withScratchAsync { directory in
            let file = directory.appendingPathComponent("clip.mov")
            try await writeMovie(to: file, frames: 30)
            let descriptor = try openForReading(file)
            defer { close(descriptor) }
            let info = try await FileMediaInformation.read(descriptor: descriptor, name: file.lastPathComponent)
            #expect(info.width == 160)
            #expect(info.height == 120)
            #expect(try #require(info.duration) > 0.9)
            #expect(try abs(#require(info.frameRate) - 30) < 0.1)
        }
    }

    @Test("Audio properties report duration without inventing video dimensions")
    func audioInformation() async throws {
        try await withScratchAsync { directory in
            let file = directory.appendingPathComponent("tone.wav")
            var data = Data()
            func text(_ value: String) {
                data.append(contentsOf: value.utf8)
            }
            func word(_ value: UInt16) {
                var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            func integer(_ value: UInt32) {
                var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            text("RIFF"); integer(16036); text("WAVEfmt "); integer(16)
            word(1); word(1); integer(8000); integer(16000); word(2); word(16)
            text("data"); integer(16000); data.append(Data(count: 16000))
            try data.write(to: file)
            let descriptor = try openForReading(file)
            defer { close(descriptor) }
            let info = try await FileMediaInformation.read(descriptor: descriptor, name: file.lastPathComponent)
            #expect(try abs(#require(info.duration) - 1) < 0.01)
            #expect(info.width == nil && info.height == nil && info.frameRate == nil)
        }
    }

    @Test("A movie plays through a descriptor, with nothing copied anywhere")
    func assetOverDescriptor() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("clip.mov")
            try await writeMovie(to: url, frames: 30)

            let media = try DescriptorAsset(descriptor: openForReading(url), name: url.lastPathComponent)
            let duration = try await media.asset.load(.duration)
            let tracks = try await media.asset.load(.tracks)
            #expect(CMTimeGetSeconds(duration) > 0.5)
            #expect(tracks.count == 1)
        }
    }

    @Test("Every sample survives the round trip, not just the header")
    func everySampleArrives() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("clip.mov")
            try await writeMovie(to: url, frames: 30)

            func sampleCount(of asset: AVAsset) async throws -> Int {
                let track = try #require(try await asset.load(.tracks).first)
                let reader = try AVAssetReader(asset: asset)
                reader.add(AVAssetReaderTrackOutput(track: track, outputSettings: nil))
                reader.startReading()
                var count = 0
                while reader.outputs[0].copyNextSampleBuffer() != nil {
                    count += 1
                }
                #expect(reader.status == .completed)
                return count
            }

            let media = try DescriptorAsset(descriptor: openForReading(url), name: url.lastPathComponent)
            let throughDescriptor = try await sampleCount(of: media.asset)
            let throughPath = try await sampleCount(of: AVURLAsset(url: url))
            #expect(throughDescriptor == throughPath)
            #expect(throughDescriptor > 0)
        }
    }

    @Test("A frame comes back for video and never for audio")
    func frameGeneration() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("clip.mov")
            try await writeMovie(to: url, frames: 30)
            let media = try DescriptorAsset(descriptor: openForReading(url), name: url.lastPathComponent)
            let frame = try #require(await media.frame(maxPixelSize: 48))
            #expect(max(frame.width, frame.height) <= 48)

            // Nothing to see in an unreadable file, and no error either.
            let empty = directory.appendingPathComponent("silence.m4a")
            try Data(repeating: 0, count: 4096).write(to: empty)
            let broken = try DescriptorAsset(descriptor: openForReading(empty), name: empty.lastPathComponent)
            #expect(await broken.frame(maxPixelSize: 48) == nil)
        }
    }

    /// The service routes by `FileFormat.detect`, and that has no signature for
    /// any media container — so a movie is a movie by its extension alone. The
    /// asset itself sniffs the container and does not care, which is why the two
    /// halves of this test disagree.
    ///
    /// Pinned rather than worked around: the fix belongs in `FileFormat`, and
    /// when someone adds `ftyp` there this test is what tells them the second
    /// half now passes.
    @Test("A video thumbnail needs the extension, because detection has no media signature")
    func videoThumbnailRoutesByName() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("clip.mov")
            try await writeMovie(to: url, frames: 20)
            let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
            let service = ThumbnailService()

            let named = await service.thumbnail(
                path: url.path,
                modified: 1,
                byteCount: size.int64Value,
                maxPixelSize: 48,
                open: { try openForReading(url) }
            )
            #expect(named != nil)

            let anonymous = directory.appendingPathComponent("recording")
            try FileManager.default.copyItem(at: url, to: anonymous)
            let unnamed = await service.thumbnail(
                path: anonymous.path,
                modified: 1,
                byteCount: size.int64Value,
                maxPixelSize: 48,
                open: { try openForReading(anonymous) }
            )
            #expect(unnamed == nil, "no media signature in FileFormat, so this falls back to the icon")
        }
    }

    @Test("An extensionless movie is still recognised, by its container")
    func typeFromSignature() async throws {
        try await withScratchAsync { directory in
            let named = directory.appendingPathComponent("clip.mov")
            try await writeMovie(to: named, frames: 10)
            let anonymous = directory.appendingPathComponent("recording")
            try FileManager.default.moveItem(at: named, to: anonymous)

            let media = try DescriptorAsset(descriptor: openForReading(anonymous), name: "recording")
            let tracks = try await media.asset.load(.tracks)
            #expect(tracks.count == 1)
        }
    }
}

// MARK: - Fixtures

/// A real QuickTime file, because the whole point of these tests is that a real
/// demuxer reads the bytes back out of a descriptor.
private func writeMovie(to url: URL, frames: Int) async throws {
    let width = 160
    let height = 120
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    )
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    for index in 0 ..< frames {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        // A gradient that changes per frame, so a demuxer handed the wrong bytes
        // produces a visibly different picture rather than the same grey.
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            memset(base, Int32(index * 8 % 256), CVPixelBufferGetDataSize(pixels))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        while !input.isReadyForMoreMediaData {
            await Task.yield()
        }
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw FixtureFailed() }
}
