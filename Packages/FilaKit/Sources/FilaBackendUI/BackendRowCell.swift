#if canImport(UIKit)
import SnapKit
import Then
import UIKit

/// A fixed-icon row for a catalogue item: an app, a song. The image owns a
/// 30-point square whatever the artwork or the type size, and artwork that
/// arrives late lands only if the cell still shows the row it was asked
/// for.
public final class BackendRowCell: UICollectionViewListCell {
    public let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private var artworkToken = UUID()

    override public init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    override public func prepareForReuse() {
        super.prepareForReuse()
        artworkToken = UUID()
    }

    private func build() {
        iconView.do {
            $0.contentMode = .scaleAspectFit
            $0.tintColor = .secondaryLabel
            $0.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: FilaUI.IconSize.inline)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
        nameLabel.do {
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.lineBreakMode = .byTruncatingMiddle
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        detailLabel.do {
            $0.font = .preferredFont(forTextStyle: .footnote)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = .secondaryLabel
            $0.lineBreakMode = .byTruncatingMiddle
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let text = UIStackView(arrangedSubviews: [nameLabel, detailLabel]).then {
            $0.axis = .vertical
            $0.spacing = 1
            $0.alignment = .leading
        }
        let row = UIStackView(arrangedSubviews: [iconView, text]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = FilaUI.Spacing.medium
        }
        contentView.addSubview(row)
        iconView.snp.makeConstraints { make in
            make.size.equalTo(FilaUI.IconSize.file)
        }
        row.snp.makeConstraints { make in
            make.edges.equalTo(contentView.layoutMarginsGuide)
        }
        separatorLayoutGuide.snp.makeConstraints { make in
            make.leading.equalTo(nameLabel)
        }
    }

    public func configure(name: String, detail: String?, image: UIImage?) {
        nameLabel.text = name
        detailLabel.text = detail
        detailLabel.isHidden = detail?.isEmpty != false
        iconView.image = image
        iconView.contentMode = .scaleAspectFit
        iconView.clipsToBounds = false
        iconView.layer.cornerRadius = 0
        artworkToken = UUID()
        accessories = [.disclosureIndicator()]
        accessibilityLabel = [name, detail].compactMap(\.self).joined(separator: ", ")
    }

    /// Application artwork for `identifier`: whatever is cached paints now,
    /// the rest arrives from `artwork` and lands only if the cell still shows
    /// this row.
    public func showApplicationIcon(_ identifier: String, artwork: any ApplicationArtwork) {
        let token = UUID()
        artworkToken = token
        if let cached = artwork.cachedIcon(for: identifier) {
            iconView.image = cached
            return
        }
        Task { [weak self] in
            let image = await artwork.icon(for: identifier)
            guard let self, artworkToken == token else { return }
            iconView.image = image
        }
    }

    /// Square artwork with rounded corners, the way a song's cover is drawn.
    public func showCover(_ image: UIImage?, placeholder: UIImage?) {
        iconView.image = image ?? placeholder
        iconView.contentMode = image == nil ? .scaleAspectFit : .scaleAspectFill
        iconView.clipsToBounds = image != nil
        iconView.layer.cornerRadius = image == nil ? 0 : 4
    }
}
#endif
