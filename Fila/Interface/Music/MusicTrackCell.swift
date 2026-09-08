import SnapKit
import Then
import UIKit

final class MusicTrackCell: UITableViewCell {
    private var track: MusicLibraryTrack?
    private let coverView = MusicArtworkView()
    private let titleLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .headline)
        $0.adjustsFontForContentSizeCategory = true
        $0.lineBreakMode = .byTruncatingTail
    }
    private let subtitleLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .footnote)
        $0.textColor = .secondaryLabel
        $0.adjustsFontForContentSizeCategory = true
        $0.lineBreakMode = .byTruncatingTail
    }
    private let durationLabel = UILabel().then {
        $0.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .regular))
        $0.textColor = .secondaryLabel
        $0.textAlignment = .right
        $0.adjustsFontForContentSizeCategory = true
        $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        $0.setContentHuggingPriority(.required, for: .horizontal)
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        let names = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel]).then {
            $0.axis = .vertical
            $0.spacing = 3
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        let row = UIStackView(arrangedSubviews: [coverView, names, durationLabel]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = 12
        }
        contentView.addSubview(row)
        row.snp.makeConstraints { $0.edges.equalTo(contentView.layoutMarginsGuide) }
        coverView.snp.makeConstraints { $0.size.equalTo(44) }
        accessoryType = .detailDisclosureButton
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverView.reset()
        track = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSubtitle()
    }

    func show(_ track: MusicLibraryTrack) {
        self.track = track
        titleLabel.text = track.title.isEmpty ? String(localized: "Untitled") : track.title
        durationLabel.text = Self.durationText(track.duration)
        updateSubtitle()
        coverView.show(id: track.id, pixelSize: 120)
        accessibilityLabel = [titleLabel.text, track.artist, track.album, durationLabel.text]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func updateSubtitle() {
        guard let track else { return }
        let parts = bounds.width < 600 ? [track.artist] : [track.artist, track.album]
        let text = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        if subtitleLabel.text != text { subtitleLabel.text = text }
        subtitleLabel.isHidden = text.isEmpty
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
