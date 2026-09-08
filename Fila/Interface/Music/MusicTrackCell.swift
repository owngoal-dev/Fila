import SnapKit
import Then
import UIKit

final class MusicTrackCell: UITableViewCell {
    private let titleLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .body)
        $0.adjustsFontForContentSizeCategory = true
        $0.lineBreakMode = .byTruncatingTail
    }
    private let artistLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .caption1)
        $0.textColor = .secondaryLabel
        $0.adjustsFontForContentSizeCategory = true
        $0.lineBreakMode = .byTruncatingTail
    }
    private let albumLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .subheadline)
        $0.textColor = .secondaryLabel
        $0.adjustsFontForContentSizeCategory = true
        $0.lineBreakMode = .byTruncatingTail
        $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    private let durationLabel = UILabel().then {
        $0.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
        $0.textColor = .secondaryLabel
        $0.adjustsFontForContentSizeCategory = true
        $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        $0.setContentHuggingPriority(.required, for: .horizontal)
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        let names = UIStackView(arrangedSubviews: [titleLabel, artistLabel]).then {
            $0.axis = .vertical
            $0.spacing = 3
        }
        let row = UIStackView(arrangedSubviews: [names, albumLabel, UIView(), durationLabel]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = 12
        }
        contentView.addSubview(row)
        row.snp.makeConstraints { make in
            make.edges.equalTo(contentView.layoutMarginsGuide)
        }
        names.snp.makeConstraints { make in
            make.width.equalTo(row).multipliedBy(0.5).priority(.high)
        }
        albumLabel.snp.makeConstraints { make in
            make.width.lessThanOrEqualTo(row).multipliedBy(0.3)
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ track: MusicLibraryTrack) {
        titleLabel.text = track.title.isEmpty ? String(localized: "Untitled") : track.title
        artistLabel.text = track.artist
        artistLabel.isHidden = track.artist.isEmpty
        albumLabel.text = track.album
        durationLabel.text = Self.durationText(track.duration)
        accessibilityLabel = [titleLabel.text, track.artist, track.album, durationLabel.text]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration >= 0, duration < Double(Int.max) else { return "—" }
        let seconds = Int(duration)
        if seconds >= 3600 {
            return String(format: "%lld:%02lld:%02lld", Int64(seconds / 3600), Int64(seconds / 60 % 60), Int64(seconds % 60))
        }
        return String(format: "%lld:%02lld", Int64(seconds / 60), Int64(seconds % 60))
    }
}
