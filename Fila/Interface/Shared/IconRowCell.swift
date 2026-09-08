import FilaProtocol
import SnapKit
import Then
import UIKit

/// A shared fixed-icon row for files, sidebar destinations and applications.
///
/// The image always owns a 30pt square, independent of artwork or Dynamic Type.
/// File rows can also put their size in a separate right-aligned column.
final class IconRowCell: UICollectionViewListCell {
    /// The type icon, and the seam a thumbnail arrives through.
    ///
    /// `configure` resets it before the caller installs any cached thumbnail.
    let iconView = UIImageView()

    /// The corner mark that says "this row is a symlink".
    ///
    /// It exists because the icon no longer says so: a link draws its target's
    /// picture, so without this a link to a PNG and the PNG itself are the same
    /// row. Drawn over the icon rather than in a column of its own — a column
    /// would be a second thing to scan on every line for a fact that matters on
    /// one line in twenty. Finder's own alias arrow, laid over the whole icon:
    /// the artwork already sits in the bottom-left corner of a full canvas, so
    /// it lands where a Mac user expects it without any placement of its own.
    private let linkBadge = UIImageView()
    private let appBadge = UIImageView()
    private let favoriteBadge = UIImageView()

    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let sizeLabel = UILabel()

    /// Identifies the artwork load in flight, so a cell reused mid-fetch never
    /// ends up showing the previous row's app.
    private var iconToken = UUID()
    private var thumbnailTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        iconToken = UUID()
    }

    deinit { thumbnailTask?.cancel() }

    // MARK: - Hierarchy

    /// Big enough to read at a glance on the corner of a 30pt icon, small
    /// enough not to be the picture.
    private static let badgeSize: CGFloat = 12

    private func build() {
        iconView.do {
            $0.contentMode = .scaleAspectFit
            $0.tintColor = .secondaryLabel
            $0.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: FilaUI.IconSize.inline)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }

        linkBadge.do {
            $0.image = UIImage(named: "FileIcons/alias")?.withRenderingMode(.alwaysOriginal)
            $0.contentMode = .scaleAspectFit
        }
        iconView.addSubview(linkBadge)

        favoriteBadge.do {
            $0.image = UIImage(systemName: "star.circle.fill")
            $0.tintColor = .secondaryLabel
            $0.backgroundColor = .systemBackground
            $0.layer.cornerRadius = Self.badgeSize / 2
            $0.clipsToBounds = true
        }
        iconView.addSubview(favoriteBadge)

        appBadge.do {
            $0.contentMode = .scaleAspectFit
            $0.tintColor = .systemBrown
            $0.backgroundColor = .systemBackground
            $0.layer.cornerRadius = 4
            $0.clipsToBounds = true
        }
        iconView.addSubview(appBadge)

        nameLabel.do {
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            // Middle rather than tail: on this filesystem the extension is half of
            // what identifies a file, and a reversed-domain name is the other half.
            $0.lineBreakMode = .byTruncatingMiddle
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        for label in [detailLabel, sizeLabel] {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
        }
        detailLabel.do {
            $0.lineBreakMode = .byTruncatingMiddle
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        sizeLabel.do {
            $0.textAlignment = .right
            // The name gives way, the size never does: a size that ellipsises is
            // not a size, and it is one short word beside a name that may be sixty
            // characters long.
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }

        let text = UIStackView(arrangedSubviews: [nameLabel, detailLabel]).then {
            $0.axis = .vertical
            $0.spacing = 1
            $0.alignment = .leading
        }

        let row = UIStackView(arrangedSubviews: [iconView, text, sizeLabel]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = FilaUI.Spacing.medium
        }
        contentView.addSubview(row)

        iconView.snp.makeConstraints { make in
            make.size.equalTo(FilaUI.IconSize.file)
        }
        linkBadge.snp.makeConstraints { make in
            // The arrow sits in the artwork's bottom-left corner, so scaling the
            // whole canvas from that corner enlarges the arrow and leaves it put.
            // At 1× it is unreadable on a phone.
            make.width.height.equalTo(iconView).multipliedBy(2)
            make.leading.bottom.equalTo(iconView)
        }
        favoriteBadge.snp.makeConstraints { make in
            make.size.equalTo(Self.badgeSize)
            make.leading.bottom.equalTo(iconView)
        }
        appBadge.snp.makeConstraints { make in
            make.width.equalTo(iconView).multipliedBy(0.55)
            make.height.equalTo(appBadge.snp.width)
            make.trailing.bottom.equalTo(iconView)
        }
        row.snp.makeConstraints { make in
            make.edges.equalTo(contentView.layoutMarginsGuide)
        }
        // Without this the separator starts under the icon, because a cell
        // with a custom content view has nothing else to measure from.
        separatorLayoutGuide.snp.makeConstraints { make in
            make.leading.equalTo(nameLabel)
        }
    }

    // MARK: - Content

    func configure(
        name: String,
        detail: String? = nil,
        image: UIImage?,
        nameColor: UIColor = .label,
        tintColor: UIColor = .secondaryLabel,
        highlight: String? = nil
    ) {
        nameLabel.textColor = nameColor
        // A search hit tints the part that matched, the way a mention is
        // tinted: the text itself is left exactly as it is, so a list of
        // near-identical names says why each one is there.
        if let highlight, !highlight.isEmpty,
           let range = name.range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive])
        {
            let text = NSMutableAttributedString(string: name, attributes: [.foregroundColor: nameColor])
            text.addAttribute(.foregroundColor, value: UIColor.tintColor, range: NSRange(range, in: name))
            nameLabel.attributedText = text
        } else {
            nameLabel.text = name
        }
        detailLabel.text = detail
        detailLabel.isHidden = detail?.isEmpty != false
        sizeLabel.text = nil
        sizeLabel.isHidden = true
        iconView.image = image
        iconView.tintColor = tintColor
        iconView.alpha = 1
        iconView.contentMode = .scaleAspectFit
        iconView.clipsToBounds = false
        iconView.layer.cornerRadius = 0
        linkBadge.isHidden = true
        appBadge.isHidden = true
        favoriteBadge.isHidden = true
        thumbnailTask?.cancel()
        iconToken = UUID()
        accessories = [.disclosureIndicator()]
        accessibilityLabel = [name, detail].compactMap(\.self).joined(separator: ", ")
    }

    func showProperties(action: @escaping () -> Void) {
        let button = UIButton(type: .infoLight).then {
            $0.accessibilityLabel = String(localized: "Properties")
            $0.addAction(UIAction { _ in action() }, for: .touchUpInside)
        }
        button.snp.makeConstraints { $0.size.equalTo(FilaUI.minimumTapTarget) }
        let info = UICellAccessory.customView(configuration: .init(
            customView: button,
            placement: .trailing(displayed: .whenNotEditing, at: { _ in 0 }),
            reservedLayoutWidth: .custom(FilaUI.minimumTapTarget)
        ))
        accessories.insert(info, at: 1)
    }

    func showFavoriteBadge() {
        favoriteBadge.isHidden = false
    }

    /// Application artwork: the row's icon for a bundle, the corner badge for
    /// a container. Cached artwork paints now; the rest arrives from
    /// `AppFolderDisplay.icon` and lands only if the cell still shows this row.
    func showApplicationIcon(_ identifier: String?, asBadge: Bool) {
        let target = asBadge ? appBadge : iconView
        target.isHidden = false
        let token = UUID()
        iconToken = token
        if let cached = AppFolderDisplay.cachedIcon(for: identifier) {
            target.image = cached
            return
        }
        // A bundle keeps its type artwork until the real icon lands; a badge
        // has nothing else to show.
        if asBadge {
            target.image = AppFolderDisplay.placeholderIcon
        }
        Task { [weak self] in
            let image = await AppFolderDisplay.icon(for: identifier)
            guard let self, iconToken == token else { return }
            target.image = image
        }
    }

    /// A picture of the file itself where one can be made cheaply — see
    /// `ThumbnailCache`. Lands only if the cell still shows this row.
    func showThumbnail(for path: String, node: FileNode, session: FileSession) {
        guard node.kind == .regular || node.link?.resolvedKind == .regular else { return }
        let token = UUID()
        iconToken = token
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            if let executable = await FilePresentation.executableImage(for: path, node: node, session: session) {
                guard let self, iconToken == token else { return }
                iconView.image = executable
                return
            }
            guard node.kind == .regular, FilePresentation.format(of: node) == .image,
                  let thumbnail = await ThumbnailCache.shared.thumbnail(for: path, node: node, session: session),
                  let self, iconToken == token else { return }
            iconView.image = thumbnail
            iconView.contentMode = .scaleAspectFill
            iconView.clipsToBounds = true
            iconView.layer.cornerRadius = 4
        }
    }

    func configure(_ node: FileNode, presentation: AppFolderPresentation? = nil) {
        let presentation = node.kind == .directory ? presentation : nil
        let image = FilePresentation.image(for: node)
        configure(
            name: presentation?.name ?? node.name,
            detail: presentation.map { [$0.detail, node.name].compactMap(\.self).joined(separator: " · ") }
                ?? Self.detail(for: node),
            image: image,
            nameColor: presentation == nil ? .label : .systemBrown
        )
        // File rows are always two lines, so a zero-mtime file neither shrinks
        // its row nor shifts the size column.
        detailLabel.isHidden = false
        sizeLabel.text = FilePresentation.sizeLabel(for: node)
        sizeLabel.isHidden = sizeLabel.text?.isEmpty != false
        linkBadge.isHidden = node.kind != .symbolicLink
        if let presentation {
            let isApplication = URL(fileURLWithPath: node.name).pathExtension.lowercased() == "app"
            showApplicationIcon(presentation.applicationIdentifier, asBadge: !isApplication)
        }
        // Hidden files stay legible and stay obviously different, which is what
        // "show hidden" is turned on to see.
        iconView.alpha = node.isHidden ? 0.6 : 1

        accessories = [
            .multiselect(displayed: .whenEditing),
            .disclosureIndicator(
                displayed: .whenNotEditing,
                options: .init(isHidden: !node.isNavigable, reservedLayoutWidth: .standard)
            ),
        ]

        accessibilityLabel = [nameLabel.text, sizeLabel.text, detailLabel.text]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// The second line: where a link points, or when the item last changed.
    ///
    /// A symlink's target displaces its date because the target is the answer
    /// to the question a link raises, and the row has one line to give.
    private static func detail(for node: FileNode) -> String {
        if node.kind == .symbolicLink, let link = node.link {
            return "→ " + link.target
        }
        return FilePresentation.dateLabel(node.modified)
    }
}
