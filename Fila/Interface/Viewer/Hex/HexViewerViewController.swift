import AlertController
import FilaBackendUI
import FilaFormats
import FilaProtocol
import SnapKit
import Then
import UIKit

/// The floor. Every file has one of these, which is why `FileFormat` has a
/// `.binary` case rather than a nil.
///
/// Windowed: the table has one row per sixteen bytes and the rows fetch pages of
/// the file as they scroll into view, so a large file uses the same bounded
/// page cache as a small one. Reading it whole would be simpler and
/// would also be the difference between a viewer and a jetsam.
///
/// Read-only, deliberately. Editing bytes in place means `pwrite` onto the
/// original — the one thing the atomic-write rule forbids — and doing it
/// atomically means rewriting a 4 GB file to change one byte. Neither is worth
/// building before someone asks for it.
final class HexViewerViewController: TabContentViewController {
    private var bytesPerRow = 8
    private static let pageByteCount = 64 * 1024
    private static let cachedPageCount = 32

    private let file: DescriptorFile
    private let table = UITableView(frame: .zero, style: .plain)
    private var pages: [Int64: Data] = [:]
    private var pageOrder: [Int64] = []

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

        table.do {
            $0.dataSource = self
            $0.separatorStyle = .none
            $0.rowHeight = 52
            $0.estimatedRowHeight = 0
            $0.allowsSelection = false
            $0.register(HexRowCell.self, forCellReuseIdentifier: HexRowCell.identifier)
        }
        view.addSubview(table)
        table.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        let container = parent as? ViewerContainerViewController
        container?.childMenuElements = [UIAction(
            title: String(localized: "Go to Offset"),
            image: UIImage(systemName: "number"),
            attributes: file.byteCount > 0 ? [] : .disabled
        ) { [weak self] _ in self?.goToOffset() }]
        container?.refreshBarItems()
        if file.byteCount == 0 {
            table.backgroundView = StatusView(content: .message(
                symbol: "doc",
                title: String(localized: "Empty File"),
                detail: nil
            ))
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        pages.removeAll()
        pageOrder.removeAll()
        table.reloadWithAnimation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = max(1, table.bounds.width - table.layoutMargins.left - table.layoutMargins.right)
        let font = HexRowCell.font
        let characterWidth = "0".size(withAttributes: [.font: font]).width
        let newWidth = width >= characterWidth * 68 ? 16 : 8
        let offsetDigits = max(8, String(max(0, file.byteCount - 1), radix: 16).count)
        let lines = ceil(CGFloat(offsetDigits) * characterWidth / width)
            + ceil(CGFloat(newWidth * 4 + 4) * characterWidth / width)
        // A fixed height keeps row bookkeeping constant for multi-gigabyte
        // files. Derive it from the current font instead of asking Auto Layout
        // to estimate hundreds of millions of individual row heights.
        let rowHeight = ceil(lines * font.lineHeight) + 16
        guard newWidth != bytesPerRow || table.rowHeight != rowHeight else { return }
        let offset = Int64(table.indexPathsForVisibleRows?.first?.row ?? 0) * Int64(bytesPerRow)
        bytesPerRow = newWidth
        table.rowHeight = rowHeight
        table.reloadData()
        if offset < file.byteCount {
            table.scrollToRow(
                at: IndexPath(row: Int(offset / Int64(bytesPerRow)), section: 0),
                at: .top,
                animated: false
            )
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            table.reloadData()
            view.setNeedsLayout()
        }
    }

    /// The bytes for one row, read through the page the row falls in. A row is
    /// never a read of its own: sixteen-byte `pread`s while a finger is on the
    /// scroll bar is thousands of syscalls a second.
    private func bytes(forRow row: Int) -> Data {
        let offset = Int64(row) * Int64(bytesPerRow)
        let pageIndex = offset / Int64(Self.pageByteCount)
        let page = page(pageIndex)
        let start = Int(offset - pageIndex * Int64(Self.pageByteCount))
        guard start < page.count else { return Data() }
        return page.subdata(in: start ..< min(start + bytesPerRow, page.count))
    }

    private func page(_ index: Int64) -> Data {
        if let cached = pages[index] {
            return cached
        }
        let data = (try? file.read(
            at: index * Int64(Self.pageByteCount),
            count: Self.pageByteCount
        )) ?? Data()
        pages[index] = data
        pageOrder.append(index)
        if pageOrder.count > Self.cachedPageCount {
            pages.removeValue(forKey: pageOrder.removeFirst())
        }
        return data
    }

    @objc private func goToOffset() {
        let alert = AlertInputViewController(
            title: String.LocalizationValue("Go to Offset"),
            message: String.LocalizationValue("Enter a decimal offset, or a hexadecimal offset with a 0x prefix."),
            placeholder: .noPlaceholder,
            text: "",
            doneButtonText: String.LocalizationValue("Go")
        ) { [weak self] text in
            guard let self else { return }
            // Silently doing nothing is how this read as broken: a typo and a
            // number past the end of the file both looked like a dead button.
            guard let offset = HexWindow.parseOffset(text) else {
                explain(String(localized: "That is not a valid offset. Enter a decimal offset, or a hexadecimal offset with a 0x prefix."))
                return
            }
            guard offset < file.byteCount else {
                explain(String(
                    format: String(localized: "This offset is past the end of the file. Enter 0x%llx or less."),
                    max(0, file.byteCount - 1)
                ))
                return
            }
            let row = Int(offset / Int64(bytesPerRow))
            table.scrollToRow(at: IndexPath(row: row, section: 0), at: .top, animated: false)
        }
        present(alert, animated: true)
    }

    private func explain(_ message: String) {
        let alert = AlertViewController(
            title: String(localized: "Go to Offset"),
            message: message
        ) { [weak self] context in
            context.allowSimpleDispose()
            context.addAction(title: String.LocalizationValue("Close")) { context.dispose() }
            context.addAction(title: String.LocalizationValue("Go to Offset"), attribute: .accent) {
                context.dispose { self?.goToOffset() }
            }
        }
        present(alert, animated: true)
    }
}

/// **Deliberately not diffable, and this is the one screen in the app that is
/// not.** Every other list here moved to `UITableViewDiffableDataSource`; this
/// one cannot, because a snapshot must enumerate every identifier up front and
/// this table's row count is the file's length.
///
/// A 4 GB disk image is 4,294,967,296 ÷ 16 =
/// **268,435,456 rows**. Even at eight bytes an identifier that is over 2 GB of
/// identifiers before the snapshot's own hash index, to draw the forty rows that
/// fit on screen, on a device whose whole app footprint is a few hundred
/// megabytes. `numberOfRowsInSection` answers the same question with one
/// division and no allocation.
///
/// A windowed snapshot holding only the loaded pages was considered and is
/// worse: the table would then be as long as the window rather than as long as
/// the file, which breaks the scroll indicator's proportion — the only sense of
/// scale a hex dump has — and breaks *Go to Offset*, which scrolls to a row that
/// would not be in the snapshot yet. Losing large-file support to gain a
/// uniform data source is a bad trade, so it was not made.
extension HexViewerViewController: UITableViewDataSource {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        Int(file.byteCount / Int64(bytesPerRow) + (file.byteCount % Int64(bytesPerRow) == 0 ? 0 : 1))
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: HexRowCell.identifier, for: indexPath)
        (cell as? HexRowCell)?.show(
            offset: Int64(indexPath.row) * Int64(bytesPerRow),
            bytes: bytes(forRow: indexPath.row),
            width: bytesPerRow
        )
        return cell
    }
}

/// Offset above bytes keeps the data legible on a phone. Dynamic Type wraps
/// the line instead of shrinking a sixteen-byte row into unreadable text.
final class HexRowCell: UITableViewCell {
    static let identifier = "HexRow"

    private let line = UILabel()
    static var font: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        line.do {
            $0.font = Self.font
            $0.adjustsFontForContentSizeCategory = true
            $0.numberOfLines = 0
            $0.lineBreakMode = .byCharWrapping
        }
        contentView.addSubview(line)
        line.snp.makeConstraints { make in
            make.leading.trailing.equalTo(contentView.layoutMarginsGuide)
            make.top.equalToSuperview().offset(FilaUI.Spacing.small)
            make.bottom.equalToSuperview().offset(-FilaUI.Spacing.small)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(offset: Int64, bytes: Data, width: Int) {
        var hex = ""
        var ascii = ""
        for index in 0 ..< width {
            if index < bytes.count {
                let byte = bytes[bytes.startIndex + index]
                hex += String(format: "%02x ", byte)
                ascii.append(byte >= 0x20 && byte < 0x7F ? Character(UnicodeScalar(byte)) : ".")
            } else {
                hex += "   "
                ascii.append(" ")
            }
            if index == width / 2 - 1 {
                hex += " "
            }
        }
        line.font = Self.font
        let text = NSMutableAttributedString(
            string: String(format: "%08llx\n", offset),
            attributes: [.foregroundColor: UIColor.secondaryLabel]
        )
        text.append(NSAttributedString(string: hex + " |" + ascii + "|", attributes: [.foregroundColor: UIColor.label]))
        line.attributedText = text
    }
}
