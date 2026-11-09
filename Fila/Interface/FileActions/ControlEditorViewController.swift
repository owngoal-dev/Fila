import AlertController
import FilaBackendUI
import SnapKit
import Then
import UIKit

/// A package's `control` file as text: the one place a package's identity is
/// written, and what people edit before putting a `.deb` back together.
///
/// Saving hands the text back rather than writing it: the caller owns the
/// archive it came out of, and this screen has no session to write with.
final class ControlEditorViewController: UIViewController {
    private let textView = UITextView()
    private let text: String
    private let declared: String
    private let save: (String) -> Void

    init(text: String, declared: String, save: @escaping (String) -> Void) {
        self.text = text
        self.declared = declared
        self.save = save
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Control")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) },
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "Cancel")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Save"),
            style: .done,
            target: self,
            action: #selector(commit),
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func present(
        from presenter: UIViewController,
        text: String,
        declared: String,
        save: @escaping (String) -> Void,
    ) {
        let editor = ControlEditorViewController(text: text, declared: declared, save: save)
        presenter.presentAsSheet(UINavigationController(rootViewController: editor))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let note = UILabel().then {
            $0.font = .preferredFont(forTextStyle: .footnote)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = .secondaryLabel
            $0.numberOfLines = 0
            // The architecture the package itself declares, said before anyone
            // edits the field that decides it.
            $0.text = String(
                localized: "This package is declared as \(declared), and packing keeps that label.",
            )
        }
        textView.do {
            $0.text = text
            $0.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            $0.adjustsFontForContentSizeCategory = true
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            // A smart quote or dash typed into a package's control file is a
            // field dpkg reads as a different value.
            $0.smartQuotesType = .no
            $0.smartDashesType = .no
            $0.smartInsertDeleteType = .no
            $0.spellCheckingType = .no
            $0.keyboardDismissMode = .interactive
            $0.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            $0.alwaysBounceVertical = true
        }
        view.addSubview(note)
        view.addSubview(textView)
        note.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(FilaUI.Spacing.large)
            make.leading.trailing.equalTo(view.layoutMarginsGuide)
        }
        textView.snp.makeConstraints { make in
            make.top.equalTo(note.snp.bottom).offset(FilaUI.Spacing.compact)
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    @objc private func commit() {
        view.endEditing(true)
        let edited = textView.text ?? ""
        do {
            // The same check the writer runs: failing here keeps the sheet open
            // with the text still on screen, instead of writing a package whose
            // control cannot name itself.
            let validated = try DebianPackageBuilder.validated(edited)
            dismiss(animated: true) { self.save(validated) }
        } catch let failure as DebianPackageBuilder.Failure {
            presentMessage(String(localized: "The Control File Was Not Saved"), message: failure.message)
        } catch {
            presentMessage(String(localized: "The Control File Was Not Saved"), message: error.localizedDescription)
        }
    }
}
