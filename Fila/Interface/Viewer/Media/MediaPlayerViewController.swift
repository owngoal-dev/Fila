import AVFoundation
import AVKit
import FilaMedia
import FilaProtocol
import SnapKit
import UIKit

/// `AVPlayerViewController` over the descriptor `filad` opened, with no copy
/// anywhere.
///
/// The file is usually somewhere `mobile` cannot open, and `AVPlayer` wants a
/// URL — so `FilaMedia.DescriptorAsset` gives it one under a scheme nothing
/// resolves, and answers every byte range out of the descriptor. Playback starts
/// at once however large the file is, scrubbing seeks instead of downloading,
/// and there is no ceiling to refuse above. `DescriptorAsset` carries the
/// measurements behind that, including why `/dev/fd/<n>` is not the answer.
final class MediaPlayerViewController: UIViewController {
    private let details: FileDetails
    private let file: DescriptorFile
    private let isAudio: Bool
    private var nowPlaying: AudioNowPlayingSession?
    private var videoPlaybackObservation: NSKeyValueObservation?
    private var startsAudioOnAppearance = false
    /// Held for the life of the screen: the asset reads through it, so releasing
    /// it closes the descriptor out from under the player.
    private var media: DescriptorAsset?
    private var player: AVPlayerViewController?

    private var container: ViewerContainerViewController? { parent as? ViewerContainerViewController }
    private var fileName: String { URL(fileURLWithPath: details.path).lastPathComponent }

    init(details: FileDetails, file: DescriptorFile, isAudio: Bool) {
        self.isAudio = isAudio
        self.details = details
        self.file = file
        super.init(nibName: nil, bundle: nil)
        title = fileName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        do {
            // The asset outlives this call and closes what it is given, so it
            // gets its own descriptor rather than the one the container owns.
            let asset = DescriptorAsset(descriptor: try file.duplicate(), name: fileName)
            media = asset
            play(asset)
        } catch {
            showFailure(error)
            return
        }

        container?.confirmReplacement = { [weak self] _, perform in
            self?.nowPlaying?.stop()
            self?.player?.player?.pause()
            perform()
        }
        container?.refreshBarItems()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if startsAudioOnAppearance {
            startsAudioOnAppearance = false
            prepareAudioSession()
            player?.player?.play()
        }
    }

    private func prepareAudioSession() {
        // Activate only when playback starts, never while loading a hidden tab.
        // Playback audio stays audible when the device's mute switch is on.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func play(_ media: DescriptorAsset) {
        if !isAudio { prepareAudioSession() }
        let controller = AVPlayerViewController()
        let playback = AVPlayer(playerItem: AVPlayerItem(asset: media.asset))
        controller.player = playback
        if isAudio {
            controller.updatesNowPlayingInfoCenter = false
            nowPlaying = AudioNowPlayingSession(player: playback, asset: media.asset, fileName: fileName)
            startsAudioOnAppearance = true
        } else {
            AudioNowPlayingSession.videoBeganPlayback(controller)
            videoPlaybackObservation = playback.observe(\.rate, options: [.new]) { [weak controller] _, _ in
                Task { @MainActor [weak controller] in
                    guard let controller, let playback = controller.player, playback.rate > 0 else { return }
                    AudioNowPlayingSession.videoBeganPlayback(controller)
                }
            }
        }
        addChild(controller)
        view.addSubview(controller.view)
        controller.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        controller.didMove(toParent: self)
        player = controller
        if !isAudio { playback.play() }
    }

    private func showFailure(_ error: Error) {
        let status = StatusView(content: .message(
            symbol: "exclamationmark.triangle",
            title: String(localized: "Unable to Play This File"),
            detail: FailureMessage.text(for: error)
        ))
        view.addSubview(status)
        status.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

}
