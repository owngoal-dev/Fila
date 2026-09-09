import FilaBackendUI
import FilaProtocol
import PDFKit
import SnapKit
import Then
import UIKit

/// PDFKit, over the bytes the descriptor gave us.
///
/// `PDFDocument(data:)` rather than `PDFDocument(url:)` for the same reason
/// every other viewer here avoids a URL: the app is `mobile`, and a second open
/// of the path would be the one the kernel refuses.
final class PDFViewerViewController: TabContentViewController {
    private let file: DescriptorFile
    private let pdfView = PDFView()
    private let pageLabel = UILabel()

    init(details: FileDetails, file: DescriptorFile) {
        self.file = file
        super.init(nibName: nil, bundle: nil)
        title = URL(fileURLWithPath: details.path).lastPathComponent
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        pdfView.do {
            $0.autoScales = true
            $0.displayMode = .singlePage
            $0.usePageViewController(true)
            $0.displayDirection = .vertical
            $0.backgroundColor = .secondarySystemBackground
        }
        pageLabel.do {
            $0.font = .preferredFont(forTextStyle: .footnote)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = .secondaryLabel
            $0.textAlignment = .center
        }
        view.addSubview(pdfView)
        view.addSubview(pageLabel)
        pdfView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.bottom.equalTo(pageLabel.snp.top).offset(-FilaUI.Spacing.small)
        }
        pageLabel.snp.makeConstraints { make in
            make.leading.trailing.equalTo(view.layoutMarginsGuide)
            make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-FilaUI.Spacing.small)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updatePage),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        do {
            let data = try file.readAll(limit: ViewerLimits.inMemoryDocumentByteCount)
            guard let document = PDFDocument(data: data) else {
                throw ViewerFailure.unsupportedContent(
                    String(localized: "Unable to open this PDF. Open it as Hex to see its contents.")
                )
            }
            guard document.pageCount <= 10000 else {
                throw ViewerFailure.unsupportedContent(String(localized: "This PDF has too many pages to preview."))
            }
            pdfView.document = document
            updatePage()
        } catch {
            pdfView.isHidden = true
            let label = UILabel().then {
                $0.text = FailureMessage.text(for: error)
                $0.numberOfLines = 0
                $0.textAlignment = .center
                $0.textColor = .secondaryLabel
            }
            view.addSubview(label)
            label.snp.makeConstraints { make in
                make.centerY.equalToSuperview()
                make.leading.trailing.equalTo(view.readableContentGuide)
            }
        }
    }

    @objc private func updatePage() {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return }
        pageLabel.text = String(
            format: String(localized: "Page %lld of %lld"),
            Int64(document.index(for: page) + 1),
            Int64(document.pageCount)
        )
    }
}
