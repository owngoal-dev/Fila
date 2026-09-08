import FilaLog
import SnapKit
import Then
import UIKit

/// A selected log record remains readable while newer records arrive behind it.
final class LogRecordViewController: UIViewController {
    private let record: FilaLog.Record

    init(record: FilaLog.Record) {
        self.record = record
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Log Entry")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [record] _ in
                    UIPasteboard.general.string = LogViewController.exportLine(record)
                },
            ])
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "More")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let textView = UITextView().then {
            $0.isEditable = false
            $0.font = FilaUI.Font.monospacedBody
            $0.adjustsFontForContentSizeCategory = true
            $0.text = LogViewController.exportLine(record)
            $0.textContainerInset = FilaUI.textContainerInset
        }
        view.addSubview(textView)
        textView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }
}
