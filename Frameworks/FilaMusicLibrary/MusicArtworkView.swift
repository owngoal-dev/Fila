import FilaCore
import SnapKit
import Then
import UIKit

/// Shared artwork and placeholder for song rows and the large details preview.
final class MusicArtworkView: UIView {
    private var trackID: Int64?
    private var load: Task<Void, Never>?
    private let imageView = UIImageView()
    private let noteView = UIImageView(image: UIImage(systemName: "music.note")).then {
        $0.contentMode = .scaleAspectFit
        $0.tintColor = .tertiaryLabel
    }

    init() {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemFill
        layer.cornerRadius = 8
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        addSubview(imageView)
        addSubview(noteView)
        imageView.snp.makeConstraints { $0.edges.equalToSuperview() }
        noteView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.height.equalTo(snp.width).multipliedBy(0.28)
        }
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { load?.cancel() }

    func reset() {
        load?.cancel()
        trackID = nil
        imageView.image = nil
        noteView.isHidden = false
    }

    func show(id: Int64, pixelSize: Int) {
        guard trackID != id else { return }
        reset()
        trackID = id
        load = Task { [weak self] in
            guard let data = await MusicLibraryEditor.shared.artwork(id: id, pixelSize: pixelSize),
                  !Task.isCancelled, let image = UIImage(data: data), let self else { return }
            imageView.image = image
            noteView.isHidden = true
        }
    }
}
