import AlertController
import SnapKit
import Then
import UIKit

/// AlertController owns the card; its public custom-content API lets the
/// irreversible action use system red without changing the app-wide accent.
final class PermanentDeleteConfirmation: UIViewController {
    private let heading: String
    private let message: String
    private let confirmTitle: String
    private var confirm: (() -> Void)?

    static func present(from presenter: UIViewController, title: String, message: String,
                        confirmTitle: String = String(localized: "Delete Permanently"), confirm: @escaping () -> Void) {
        let content = PermanentDeleteConfirmation(title: title, message: message, confirmTitle: confirmTitle, confirm: confirm)
        let alert = AlertViewController(contentViewController: content)
        alert.shouldDismissWhenEscapeKeyPressed = true
        presenter.present(alert, animated: true)
    }

    private init(title: String, message: String, confirmTitle: String, confirm: @escaping () -> Void) {
        heading = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.confirm = confirm
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AlertControllerConfiguration.backgroundColor
        let icon = UIImageView(image: AlertControllerConfiguration.alertImage).then {
            $0.contentMode = .scaleAspectFit
            $0.layer.cornerRadius = 12
            $0.clipsToBounds = true
        }
        icon.snp.makeConstraints { $0.size.equalTo(64) }
        let title = UILabel().then {
            $0.text = heading
            $0.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
            $0.adjustsFontForContentSizeCategory = true
            $0.textAlignment = .center
            $0.numberOfLines = 0
        }
        let detail = UILabel().then {
            $0.text = message
            $0.font = .preferredFont(forTextStyle: .footnote)
            $0.adjustsFontForContentSizeCategory = true
            $0.textAlignment = .center
            $0.numberOfLines = 0
        }
        let close = button(title: String(localized: "Close"), destructive: false) { [weak self] in self?.finish(deleting: false) }
        let delete = button(title: confirmTitle, destructive: true) { [weak self] in
            self?.finish(deleting: true)
        }
        // A vertical pair keeps the full destructive wording visible at large text sizes.
        let stack = UIStackView(arrangedSubviews: [icon, title, detail, delete, close]).then {
            $0.axis = .vertical
            $0.alignment = .center
            $0.spacing = 16
        }
        view.addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(16) }
        for child in [title, detail, delete, close] {
            child.snp.makeConstraints { $0.width.equalTo(stack) }
        }
    }

    private func finish(deleting: Bool) {
        guard let confirm else { return }
        self.confirm = nil
        dismiss(animated: true, completion: deleting ? confirm : nil)
    }

    private func button(title: String, destructive: Bool, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system).then {
            $0.configuration = UIButton.Configuration.filled().with {
                $0.title = title
                $0.baseBackgroundColor = destructive ? .systemRed : .secondarySystemBackground
                $0.baseForegroundColor = destructive ? .white : .tintColor
                $0.cornerStyle = .medium
                $0.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
            }
            $0.titleLabel?.adjustsFontForContentSizeCategory = true
            $0.titleLabel?.numberOfLines = 0
            $0.addAction(UIAction { _ in action() }, for: .touchUpInside)
        }
        button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(FilaUI.minimumTapTarget) }
        return button
    }
}
