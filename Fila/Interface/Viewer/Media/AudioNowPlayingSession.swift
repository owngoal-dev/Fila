import AVFoundation
import AVKit
import FilaMedia
import ImageIO
import MediaPlayer
import UIKit

/// One music document owns the system controls at a time. Retained hidden tabs
/// keep their player and position, but cannot publish metadata or clear a newer
/// document's controls. Ownership follows playback, not view appearance.
@MainActor
final class AudioNowPlayingSession {
    private static weak var owner: AudioNowPlayingSession?
    private static var ownerID: UUID?
    private static weak var videoController: AVPlayerViewController?
    private static var commands: [(MPRemoteCommand, Any, Bool)] = []
    private static var skipIntervals: ([NSNumber], [NSNumber])?

    private let id = UUID()
    private let player: AVPlayer
    private var info: [String: Any]
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var metadataTask: Task<Void, Never>?

    init(player: AVPlayer, asset: AVAsset, fileName: String) {
        self.player = player
        info = [
            MPMediaItemPropertyTitle: fileName,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        observations = [
            player.observe(\.rate, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.playbackChanged() }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.playbackChanged() }
            },
        ]
        if let item = player.currentItem {
            observations.append(item.observe(\.duration, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.publish() }
            })
            for name in [AVPlayerItem.timeJumpedNotification, AVPlayerItem.didPlayToEndTimeNotification,
                         AVPlayerItem.failedToPlayToEndTimeNotification] {
                notifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.publish() }
                })
            }
        }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
                Task { @MainActor [weak self] in self?.audioSessionChanged(notification) }
            })
        }
        metadataTask = Task { [weak self] in
            let metadata = await AudioMetadata.load(from: asset)
            guard !Task.isCancelled, let self else { return }
            self.apply(metadata)
            self.publish()
        }
    }

    deinit {
        metadataTask?.cancel()
        observations.forEach { $0.invalidate() }
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        player.pause()
        let token = id
        Task { @MainActor in Self.release(token, deactivateAudio: true) }
    }

    func stop() {
        player.pause()
        Self.release(id, deactivateAudio: true)
    }

    /// Native video playback keeps AVKit's own Now Playing integration. Yield
    /// before it starts so a late music metadata load cannot overwrite it.
    static func videoBeganPlayback(_ controller: AVPlayerViewController) {
        owner?.player.pause()
        if let ownerID { release(ownerID) }
        if videoController !== controller {
            videoController?.updatesNowPlayingInfoCenter = false
            videoController?.player?.pause()
        }
        videoController = controller
        controller.updatesNowPlayingInfoCenter = true
    }

    private func playbackChanged() {
        if player.rate > 0 { claim() }
        publish()
    }

    private func claim() {
        guard Self.ownerID != id else { return }
        Self.owner?.player.pause()
        Self.videoController?.updatesNowPlayingInfoCenter = false
        Self.videoController?.player?.pause()
        Self.videoController = nil
        if let previous = Self.ownerID { Self.release(previous) }
        Self.owner = self
        Self.ownerID = id
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        installCommands()
    }

    private static func release(_ token: UUID, deactivateAudio: Bool = false) {
        guard ownerID == token else { return }
        owner = nil
        ownerID = nil
        for (command, target, wasEnabled) in commands {
            command.removeTarget(target)
            command.isEnabled = wasEnabled
        }
        commands.removeAll()
        if let skipIntervals {
            let center = MPRemoteCommandCenter.shared()
            center.skipForwardCommand.preferredIntervals = skipIntervals.0
            center.skipBackwardCommand.preferredIntervals = skipIntervals.1
            Self.skipIntervals = nil
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if deactivateAudio {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func audioSessionChanged(_ notification: Notification) {
        guard Self.ownerID == id else { return }
        if notification.name == AVAudioSession.interruptionNotification,
           let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
           AVAudioSession.InterruptionType(rawValue: raw) == .began {
            // Resume stays an explicit user action: a delayed interruption-end
            // callback must not restart a document the user paused meanwhile.
            player.pause()
        } else if notification.name == AVAudioSession.routeChangeNotification,
                  let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable {
            player.pause()
        }
        publish()
    }

    private func apply(_ metadata: AudioMetadata) {
        let strings: [(String, String?)] = [
            (MPMediaItemPropertyTitle, metadata.title), (MPMediaItemPropertyArtist, metadata.artist),
            (MPMediaItemPropertyAlbumTitle, metadata.album), (MPMediaItemPropertyAlbumArtist, metadata.albumArtist),
            (MPMediaItemPropertyComposer, metadata.composer), (MPMediaItemPropertyGenre, metadata.genre),
        ]
        for (key, value) in strings { if let value { info[key] = value } }
        let numbers: [(String, Int?)] = [
            (MPMediaItemPropertyAlbumTrackNumber, metadata.trackNumber), (MPMediaItemPropertyAlbumTrackCount, metadata.trackCount),
            (MPMediaItemPropertyDiscNumber, metadata.discNumber), (MPMediaItemPropertyDiscCount, metadata.discCount),
        ]
        for (key, value) in numbers { if let value { info[key] = value } }
        if let data = metadata.artwork,
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 1_024,
               kCGImageSourceCreateThumbnailWithTransform: true,
           ] as CFDictionary) {
            let artwork = UIImage(cgImage: image)
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
    }

    private var duration: Double? {
        guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private func publish() {
        guard Self.ownerID == id else { return }
        let elapsed = player.currentTime().seconds
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed.isFinite ? max(0, elapsed) : 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.timeControlStatus == .playing ? player.rate : 0
        info[MPMediaItemPropertyPlaybackDuration] = duration
        let center = MPRemoteCommandCenter.shared()
        center.changePlaybackPositionCommand.isEnabled = duration != nil
        center.skipForwardCommand.isEnabled = duration != nil
        center.skipBackwardCommand.isEnabled = duration != nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private enum Action {
        case play, pause, toggle, stop, seek(Double), skip(Double)
    }

    private func installCommands() {
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { _ in .play }
        add(center.pauseCommand) { _ in .pause }
        add(center.togglePlayPauseCommand) { _ in .toggle }
        add(center.stopCommand) { _ in .stop }
        add(center.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent, event.positionTime.isFinite else { return nil }
            return .seek(event.positionTime)
        }
        Self.skipIntervals = (center.skipForwardCommand.preferredIntervals, center.skipBackwardCommand.preferredIntervals)
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        add(center.skipForwardCommand) { event in
            guard let event = event as? MPSkipIntervalCommandEvent, event.interval.isFinite else { return nil }
            return .skip(event.interval)
        }
        add(center.skipBackwardCommand) { event in
            guard let event = event as? MPSkipIntervalCommandEvent, event.interval.isFinite else { return nil }
            return .skip(-event.interval)
        }
    }

    private func add(_ command: MPRemoteCommand, action: @escaping (MPRemoteCommandEvent) -> Action?) {
        let wasEnabled = command.isEnabled
        let target = command.addTarget { [weak self] event in
            guard let self else { return .noSuchContent }
            guard let action = action(event) else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self, Self.ownerID == self.id else { return }
                self.perform(action)
            }
            return .success
        }
        command.isEnabled = true
        Self.commands.append((command, target, wasEnabled))
    }

    private func perform(_ action: Action) {
        switch action {
        case .play: resume()
        case .pause: player.pause()
        case .toggle:
            if player.rate == 0 { resume() } else { player.pause() }
        case .stop: stop()
        case let .seek(seconds): seek(to: seconds)
        case let .skip(seconds): seek(to: player.currentTime().seconds + seconds)
        }
        publish()
    }

    private func resume() {
        try? AVAudioSession.sharedInstance().setActive(true)
        if let duration, player.currentTime().seconds >= duration { seek(to: 0) }
        player.play()
    }

    private func seek(to seconds: Double) {
        guard seconds.isFinite, let duration else { return }
        player.seek(to: CMTime(seconds: min(max(seconds, 0), duration), preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publish() }
        }
    }
}
