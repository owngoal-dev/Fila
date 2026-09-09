#if os(iOS)
import AVFoundation
import FilaClient
import FilaLog
import FilaMedia
import FilaProtocol
import Foundation

public extension MusicLibraryEditor {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac"]
    private static let importDirectory = "/var/mobile/Media/iTunes_Control/Music/F00"

    /// Imports the audio file at `path`: staged through `files`, checked
    /// with AVFoundation, published into the library's own directory by a
    /// copy job, then registered with the library.
    func importTrack(from path: String, files: any MusicLibraryFiles) async throws -> [MusicLibraryTrack] {
        try await authorize()
        let native = try nativeLibrary()
        let staged = try await files.stage(path)
        defer {
            do { try FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
            catch { FilaLog.error("Music import staging cleanup failed: \(error)") }
        }
        let asset = AVURLAsset(url: staged)
        guard try await asset.load(.isPlayable),
              try await !asset.load(.hasProtectedContent),
              try await !asset.loadTracks(withMediaType: .audio).isEmpty,
              try await asset.loadTracks(withMediaType: .video).isEmpty
        else {
            throw error(String(localized: "Choose a playable audio file without copy protection.", bundle: MusicLibraryBackend.bundle))
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration < Double(Int64.max) / 1000 else {
            throw error(String(localized: "This audio file could not be read. Choose another file.", bundle: MusicLibraryBackend.bundle))
        }
        var metadata: [String: Any] = [
            "Title": URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            "TotalTime": NSNumber(value: Int64(duration * 1000)),
        ]
        let tags = try await MusicImportMetadata.read(from: asset)
        for (key, value) in tags.strings { metadata[key] = value }
        for (key, value) in tags.numbers { metadata[key] = NSNumber(value: value) }
        if let artwork = tags.artwork { metadata["Artwork"] = artwork }
        // A UUID name makes every import independent of existing songs and of
        // the source filename. The copy job publishes the bytes atomically.
        let name = UUID().uuidString + "." + staged.pathExtension.lowercased()
        let source = staged.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.moveItem(at: staged, to: source)
        let link = files.access
        for directory in [(Self.importDirectory as NSString).deletingLastPathComponent, Self.importDirectory] {
            do {
                guard try await link.details(of: directory).node.kind == .directory else {
                    throw FilaFailure(code: .operationFailed, systemError: ENOTDIR, path: directory)
                }
                continue
            } catch let failure as FilaFailure where failure.systemError == ENOENT { }
            do { try await link.create(.directory, at: directory) }
            catch let failure as FilaFailure where failure.systemError == EEXIST {
                guard try await link.details(of: directory).node.kind == .directory else { throw failure }
            }
        }
        let destination = Self.importDirectory + "/" + name
        // A failed copy does not establish ownership of the destination name.
        // Only a confirmed publication may be cleaned up by this import.
        try await files.copy(source, into: Self.importDirectory, subtitle: URL(fileURLWithPath: path).lastPathComponent)
        var preserveImportedFile = false
        let identifier: Int64
        do {
            try Task.checkCancellation()
            try await link.setAttributes(.newItemDefaults, at: destination)
            do { identifier = try native.importFile(atPath: destination, metadata: metadata).int64Value }
            catch {
                preserveImportedFile = (error as NSError).userInfo["PreserveImportedFile"] as? Bool == true
                FilaLog.error("Music library import failed: \(error)")
                throw self.error(String(localized: "The music library could not import this file. Try again.", bundle: MusicLibraryBackend.bundle))
            }
        } catch {
            if preserveImportedFile { throw error }
            // The native bridge keeps the copy when a remote commit is uncertain.
            // Otherwise cleanup waits for the backend's final verdict.
            do {
                try await files.delete(destination, subtitle: name)
            } catch { FilaLog.error("Music import cleanup failed at \(destination): \(error)") }
            throw error
        }
        // A stale MediaPlayer snapshot must not trigger cleanup of committed audio.
        return try await tracks(confirming: identifier, present: true)
    }
}
#endif
