import FilaBackendKit
import FilaBackendUI
import SnapKit
import Then
import UIKit

/// A decorated folder's peek: its application artwork and real location,
/// never a file preview request for the container. Committing it browses
/// this original path.
final class FolderDecorationPreviewViewController: UIViewController {
    let path: String
    private let decoration: FolderDecoration

    init(path: String, decoration: FolderDecoration) {
        self.path = path
        self.decoration = decoration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let artwork = SystemCapabilities.applicationArtwork
        let image = UIImageView(
            image: artwork?.cachedIcon(for: decoration.applicationIdentifier) ?? artwork?.placeholder
        ).then {
            $0.contentMode = .scaleAspectFit
            $0.tintColor = .systemBrown
            $0.isAccessibilityElement = false
        }
        if let artwork {
            Task { [weak image, identifier = decoration.applicationIdentifier] in
                image?.image = await artwork.icon(for: identifier)
            }
        }
        let name = UILabel().then {
            $0.font = .preferredFont(forTextStyle: .headline)
            $0.textColor = .systemBrown
            $0.text = decoration.name
        }
        let detail = UILabel().then {
            $0.font = .preferredFont(forTextStyle: .subheadline)
            $0.text = decoration.detail
            $0.textColor = .secondaryLabel
            $0.isHidden = decoration.detail == nil
        }
        let location = UILabel().then {
            $0.font = FilaUI.Font.monospacedFootnote
            $0.text = path
            $0.textColor = .secondaryLabel
        }
        for label in [name, detail, location] {
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.numberOfLines = 0
        }
        let stack = UIStackView(arrangedSubviews: [image, name, detail, location]).then {
            $0.axis = .vertical
            $0.alignment = .center
            $0.spacing = FilaUI.Spacing.medium
        }
        view.addSubview(stack)
        image.snp.makeConstraints { make in
            make.width.equalTo(96)
            make.height.equalTo(image.snp.width)
        }
        stack.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(FilaUI.Spacing.large)
            make.trailing.equalToSuperview().offset(-FilaUI.Spacing.large)
            make.top.equalToSuperview().offset(FilaUI.Spacing.large)
            make.bottom.lessThanOrEqualToSuperview().offset(-FilaUI.Spacing.large)
        }
        let size = stack.systemLayoutSizeFitting(
            CGSize(width: 320 - 2 * FilaUI.Spacing.large, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        preferredContentSize = CGSize(width: 320, height: size.height + 2 * FilaUI.Spacing.large)
    }
}
