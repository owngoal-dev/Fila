import FilaBackendUI
import SnapKit
import Then
import UIKit

/// A centred line of explanation, for a viewer that has to make the user wait.
///
/// One user left: extracting a member out of an archive, which really does have
/// to materialise the bytes before anything can open them. The media player used
/// to be the other, and is not any more — it reads through the descriptor.
final class StagingView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.do {
            $0.font = .preferredFont(forTextStyle: .callout)
            $0.textColor = .secondaryLabel
            $0.numberOfLines = 0
            $0.textAlignment = .center
        }

        let stack = UIStackView(arrangedSubviews: [label]).then {
            $0.axis = .vertical
            $0.spacing = FilaUI.Spacing.large
        }
        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func showStatus(_ message: String) {
        label.text = message
    }
}
