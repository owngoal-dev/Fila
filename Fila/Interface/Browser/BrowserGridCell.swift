import FilaProtocol
import SnapKit
import Then
import UIKit

/// The grid cell: a thumbnail where one can be made, the icon otherwise.
final class BrowserGridCell: UICollectionViewCell {
    private let image = UIImageView()
    private let appBadge = UIImageView()
    private let label = UILabel()
    /// Identifies the load in flight, so a cell that was reused mid-read does
    /// not end up showing the previous file's thumbnail.
    private var token = UUID()
    private var thumbnailTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.do {
            $0.contentMode = .scaleAspectFit
            $0.tintColor = .tintColor
        }
        appBadge.do {
            $0.contentMode = .scaleAspectFit
            $0.tintColor = .systemBrown
            $0.backgroundColor = .systemBackground
            $0.layer.cornerRadius = 6
            $0.clipsToBounds = true
        }
        image.addSubview(appBadge)
        label.do {
            $0.font = .preferredFont(forTextStyle: .footnote)
            $0.adjustsFontForContentSizeCategory = true
            $0.textAlignment = .center
            $0.numberOfLines = 2
            $0.lineBreakMode = .byTruncatingMiddle
        }
        contentView.addSubview(image)
        contentView.addSubview(label)
        image.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(6)
            make.centerX.equalToSuperview()
            make.width.equalTo(64)
            make.height.equalTo(image.snp.width)
        }
        appBadge.snp.makeConstraints { make in
            make.width.equalTo(image).multipliedBy(0.55)
            make.height.equalTo(appBadge.snp.width)
            make.trailing.bottom.equalTo(image)
        }
        label.snp.makeConstraints { make in
            make.top.equalTo(image.snp.bottom).offset(FilaUI.Spacing.compact)
            make.leading.equalToSuperview().offset(2)
            make.trailing.equalToSuperview().offset(-2)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        token = UUID()
    }

    deinit { thumbnailTask?.cancel() }

    override var isSelected: Bool {
        didSet { contentView.backgroundColor = isSelected ? .systemFill : nil }
    }

    func configure(node: FileNode, path: String, session: FileSession, presentation: AppFolderPresentation? = nil) {
        thumbnailTask?.cancel()
        let presentation = node.kind == .directory ? presentation : nil
        label.text = presentation.map { [$0.name, $0.detail].compactMap(\.self).joined(separator: "\n") } ?? node.name
        label.textColor = presentation == nil ? .label : .systemBrown
        let isApplication = presentation != nil && URL(fileURLWithPath: node.name).pathExtension.lowercased() == "app"
        appBadge.isHidden = presentation == nil || isApplication
        accessibilityLabel = [presentation?.name, presentation?.detail, node.name]
            .compactMap(\.self)
            .joined(separator: ", ")
        image.image = FilePresentation.image(for: node)
        image.contentMode = .scaleAspectFit
        image.alpha = node.isHidden ? 0.5 : 1
        contentView.layer.cornerRadius = 8
        contentView.clipsToBounds = true

        let token = UUID()
        self.token = token
        if let presentation {
            // Same seam as the thumbnail: cached artwork now, the rest later,
            // and only onto the cell that is still showing this node.
            let target = isApplication ? image : appBadge
            if let cached = AppFolderDisplay.cachedIcon(for: presentation.applicationIdentifier) {
                target.image = cached
            } else {
                if !isApplication {
                    appBadge.image = AppFolderDisplay.placeholderIcon
                }
                Task { [weak self] in
                    let artwork = await AppFolderDisplay.icon(for: presentation.applicationIdentifier)
                    guard let self, self.token == token else { return }
                    target.image = artwork
                }
            }
        }
        guard node.kind == .regular || node.link?.resolvedKind == .regular else { return }
        thumbnailTask = Task { [weak self] in
            if let executable = await FilePresentation.executableImage(for: path, node: node, session: session) {
                guard let self, self.token == token else { return }
                image.image = executable
                return
            }
            guard node.kind == .regular, FilePresentation.format(of: node) == .image else { return }
            let thumbnail = await ThumbnailCache.shared.thumbnail(for: path, node: node, session: session)
            guard let self, self.token == token, let thumbnail else { return }
            image.image = thumbnail
            image.contentMode = .scaleAspectFill
            image.clipsToBounds = true
        }
    }
}
