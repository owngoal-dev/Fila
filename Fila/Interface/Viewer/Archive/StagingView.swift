import SnapKit
import Then
import UIKit

/// A determinate bar with a line of explanation, for a viewer that has to make
/// the user wait on a number we know. Determinate rather than a spinner because
/// the wait is proportional to that number.
///
/// One user left: extracting a member out of an archive, which really does have
/// to materialise the bytes before anything can open them. The media player used
/// to be the other, and is not any more — it reads through the descriptor.
final class StagingView: UIView {
    private let label = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)
    private var total: Int64 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.do {
            $0.font = .preferredFont(forTextStyle: .callout)
            $0.textColor = .secondaryLabel
            $0.numberOfLines = 0
            $0.textAlignment = .center
        }

        let stack = UIStackView(arrangedSubviews: [label, bar]).then {
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

    func begin(message: String, total: Int64) {
        self.total = total
        label.text = message
        bar.isHidden = false
        bar.progress = 0
    }

    func advance(to done: Int64) {
        guard total > 0 else { return }
        bar.progress = Float(min(1, Double(done) / Double(total)))
    }

    func showFailure(_ message: String) {
        label.text = message
        bar.isHidden = true
    }
}
