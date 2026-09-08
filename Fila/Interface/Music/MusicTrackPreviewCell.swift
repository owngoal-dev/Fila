import SnapKit
import Then
import UIKit

final class MusicTrackPreviewCell: UITableViewCell {
    private let artwork = MusicArtworkView()
    private let titleLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .title3)
        $0.adjustsFontForContentSizeCategory = true
        $0.textAlignment = .center
        $0.numberOfLines = 0
    }
    private let subtitleLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .subheadline)
        $0.adjustsFontForContentSizeCategory = true
        $0.textColor = .secondaryLabel
        $0.textAlignment = .center
        $0.numberOfLines = 0
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        artwork.layer.cornerRadius = 14
        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel]).then {
            $0.axis = .vertical
            $0.spacing = FilaUI.Spacing.compact
        }
        contentView.addSubview(artwork)
        contentView.addSubview(labels)
        artwork.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(FilaUI.Spacing.large)
            make.centerX.equalToSuperview()
            make.width.lessThanOrEqualTo(192)
            make.width.equalTo(contentView.safeAreaLayoutGuide).offset(-FilaUI.Spacing.large * 2).priority(.high)
            make.height.equalTo(artwork.snp.width)
        }
        labels.snp.makeConstraints { make in
            make.top.equalTo(artwork.snp.bottom).offset(FilaUI.Spacing.medium)
            make.leading.trailing.equalTo(contentView.safeAreaLayoutGuide).inset(FilaUI.Spacing.large)
            make.bottom.equalToSuperview().inset(FilaUI.Spacing.large)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        artwork.reset()
    }

    func show(_ track: MusicLibraryTrack, details: MusicLibraryEditor.Details?) {
        let title = details?.values[.title] ?? track.title
        let artist = details?.values[.artist] ?? track.artist
        let album = details?.values[.album] ?? track.album
        titleLabel.text = title.isEmpty ? String(localized: "Untitled") : title
        subtitleLabel.text = [artist, album].filter { !$0.isEmpty }.joined(separator: " · ")
        artwork.show(id: track.id, pixelSize: 512)
    }
}
