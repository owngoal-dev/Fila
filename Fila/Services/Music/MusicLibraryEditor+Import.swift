import AVFoundation
import FilaLog
import FilaProtocol
import Foundation

extension MusicLibraryEditor {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac"]
    private static let importDirectory = "/var/mobile/Media/iTunes_Control/Music/F00"

    func importTrack(from path: String) async throws {
        try await authorize()
        let native = try nativeLibrary()
        let session = await FileSession.shared
        let staged = try await session.stage(path)
        defer {
            do { try FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
            catch { FilaLog.error("Music import staging cleanup failed: \(error)") }
        }
        let asset = AVURLAsset(url: staged)
        guard try await asset.load(.isPlayable),
              try await !asset.load(.hasProtectedContent),
              try await !asset.loadTracks(withMediaType: .audio).isEmpty,
              try await asset.loadTracks(withMediaType: .video).isEmpty else {
            throw error(String(localized: "Choose a playable audio file without copy protection."))
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration < Double(Int64.max) / 1000 else {
            throw error(String(localized: "This audio file has no valid duration."))
        }
        var metadata: [String: Any] = [
            "Title": URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            "TotalTime": NSNumber(value: Int64(duration * 1000)),
        ]
        for item in try await asset.load(.commonMetadata) {
            let field: String?
            switch item.commonKey {
            case .commonKeyTitle: field = "Title"
            case .commonKeyArtist: field = "Artist"
            case .commonKeyAlbumName: field = "Album"
            default: field = nil
            }
            if let field, let value = try await item.load(.stringValue), !value.isEmpty {
                metadata[field] = value
            }
        }
        // A UUID name makes every import independent of existing songs and of
        // the source filename. The copy job publishes the bytes atomically.
        let name = UUID().uuidString + "." + staged.pathExtension.lowercased()
        let source = staged.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.moveItem(at: staged, to: source)
        for directory in [(Self.importDirectory as NSString).deletingLastPathComponent, Self.importDirectory] {
            try await session.perform { link in
                do { try await link.create(.directory, at: directory) }
                catch let failure as FilaFailure where failure.systemError == EEXIST {
                    guard try await link.details(of: directory).node.kind == .directory else { throw failure }
                }
            }
        }
        let destination = Self.importDirectory + "/" + name
        let center = await session.operations
        do {
            let result = try await center.awaitJob(
                JobRequest(kind: .copy, sources: [source.path], destination: Self.importDirectory),
                kind: .copy, subtitle: URL(fileURLWithPath: path).lastPathComponent, feedback: .silent
            )
            guard result.code == .success else { throw result }
            try Task.checkCancellation()
            try await session.perform { try await $0.setAttributes(.newItemDefaults, at: destination) }
            try backupLibrary()
            do { _ = try native.importFile(atPath: destination, metadata: metadata) }
            catch {
                FilaLog.error("Music library import failed: \(error)")
                throw self.error(String(localized: "The music library could not import this file. A backup is in Music Backups in Fila’s Documents folder."))
            }
        } catch {
            // No library record refers to this file unless the native call
            // returned success. Cleanup waits for the backend's final verdict.
            do {
                let result = try await center.awaitJob(JobRequest(kind: .delete, sources: [destination]), kind: .delete, subtitle: name, feedback: .silent)
                if result.code != .success, result.systemError != ENOENT { throw result }
            } catch { FilaLog.error("Music import cleanup failed at \(destination): \(error)") }
            throw error
        }
    }
}
