import FilaClient
import FilaFormats
import FilaProtocol
import SnapKit
import Then
import UIKit

/// Each architecture has a short summary and separate lists for its metadata.
final class MachOInspectorViewController: UIViewController {
    private enum Row {
        case fact(String, String)
        /// Tapping opens the entitlements as a property list tree.
        case entitlements(PropertyListValue)
        /// Tapping opens the full list; the row shows how many there are.
        case list(String, [String])

        /// The left column, and half of the row's identity.
        var label: String {
            switch self {
            case let .fact(label, _): label
            case .entitlements: String(localized: "Entitlements")
            case let .list(label, _): label
            }
        }
    }

    /// A row's identity: which slice, and which fact about it.
    ///
    /// The slice has to be in there. A universal binary states the same facts
    /// once per architecture — "Type · Execute" appears in both the arm64 and
    /// the arm64e section — and a label on its own would put that identifier in
    /// the snapshot twice, which raises rather than draws. Within a slice no two
    /// rows share a label.
    private struct Item: Hashable {
        let slice: Int
        let label: String
    }

    private let file: DescriptorFile
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var readingTask: Task<Void, Never>?
    private var dataSource: TitledTableDataSource<Int, Item>!
    /// Architecture names, by slice. The section identifier is the slice number
    /// rather than the name because nothing stops a fat file carrying two slices
    /// that name themselves the same; the list is built once and never moves.
    private var names: [String] = []
    private var rows: [Item: Row] = [:]

    init(details: FileDetails, file: DescriptorFile, link _: any LocalFileAccess) {
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
            $0.delegate = self
            $0.backgroundView = StatusView(content: .loading(String(localized: "Loading…")))
        }
        buildDataSource()
        view.addSubview(table)
        table.snp.makeConstraints { $0.edges.equalToSuperview() }

    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        readingTask?.cancel()
        do {
            let descriptor = try file.duplicate()
            readingTask = Task { [weak self] in
                let worker = Task.detached(priority: .userInitiated) {
                    defer { close(descriptor) }
                    let image = try FilaFormats.MachOImage(descriptor: descriptor)
                    return try image.slices.map { slice in
                        try Task.checkCancellation()
                        return try (slice, image.inspect(slice), image.entitlements(of: slice)?.root)
                    }
                }
                do {
                    let architectures = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: { worker.cancel() }
                    guard !Task.isCancelled, let self else { return }
                    var updatedRows: [Item: Row] = [:]
                    var updatedNames: [String] = []
                    var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
                    for (index, architecture) in architectures.enumerated() {
                        let entitlements = architecture.2.map(Self.displayValue)
                        let built = Self.rows(
                            for: architecture.0,
                            inspection: architecture.1,
                            entitlements: entitlements,
                            isUniversal: architectures.count > 1
                        )
                        let items = built.map { Item(slice: index, label: $0.label) }
                        for (item, row) in zip(items, built) {
                            updatedRows[item] = row
                        }
                        updatedNames.append(architecture.0.architecture)
                        snapshot.appendSections([index])
                        snapshot.appendItems(items, toSection: index)
                    }
                    rows = updatedRows
                    names = updatedNames
                    table.backgroundView = nil
                    let existing = Set(dataSource.snapshot().itemIdentifiers)
                    snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(existing.contains))
                    dataSource.apply(snapshot, animatingDifferences: true, completion: nil)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.showFailure(error)
                }
            }
        } catch { showFailure(error) }
    }

    deinit { readingTask?.cancel() }

    private func showFailure(_ error: Error) {
        guard rows.isEmpty else { return }
        table.backgroundView = StatusView(content: .message(
            symbol: "exclamationmark.triangle",
            title: String(localized: "Unable to Read This File"),
            detail: FailureMessage.text(for: error)
        ))
    }

    private func buildDataSource() {
        table.register(UITableViewCell.self, forCellReuseIdentifier: "Row")
        dataSource = TitledTableDataSource(tableView: table) { [weak self] table, indexPath, item in
            let cell = table.dequeueReusableCell(withIdentifier: "Row", for: indexPath)
            var content = UIListContentConfiguration.valueCell()
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            content.text = item.label

            switch self?.rows[item] {
            case let .fact(_, value):
                content.secondaryText = value
                cell.accessoryType = .none
                cell.selectionStyle = .none
            case let .entitlements(value):
                content.secondaryText = String(format: String(localized: "%lld keys"), Int64(value.childCount))
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            case let .list(_, items):
                content.secondaryText = String(format: String(localized: "%lld items"), Int64(items.count))
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            case nil:
                break
            }

            cell.contentConfiguration = content
            return cell
        }
        dataSource.header = { [weak self] slice in self?.names[slice] }
    }

    private static func rows(
        for architecture: FilaFormats.MachOImage.Slice,
        inspection: FilaFormats.MachOImage.Inspection,
        entitlements: PropertyListValue?,
        isUniversal: Bool
    ) -> [Row] {
        var rows: [Row] = [
            .fact(String(localized: "Type"), fileType(architecture.fileType)),
            .fact(String(localized: "Signature"), architecture.isCodeSigned
                ? (inspection.isAdHoc == true ? String(localized: "Ad hoc") : String(localized: "Signed"))
                : String(localized: "None")),
            .list(String(localized: "Linked Libraries"), architecture.linkedLibraries),
        ]
        if let entitlements {
            rows.append(.entitlements(entitlements))
        } else {
            rows.append(.fact(String(localized: "Entitlements"), String(localized: "None")))
        }
        rows.append(.list(String(localized: "Runpaths"), inspection.runpaths))
        rows.append(.list(String(localized: "Load Commands"), inspection.loadCommands))
        rows.append(.list(String(localized: "Segments"), inspection.segments.map { segment in
            [
                segment.name + " · " + segment.protections,
                String(localized: "Virtual Address") + ": " + String(format: "0x%llX", segment.virtualAddress)
                    + " · " + FilePresentation.byteLabel(Int64(clamping: segment.virtualSize)),
                String(localized: "File Offset") + ": " + String(format: "0x%llX", segment.fileOffset)
                    + " · " + FilePresentation.byteLabel(Int64(clamping: segment.fileSize)),
                String(localized: "Sections") + ": " + segment.sections.joined(separator: ", "),
            ].joined(separator: "\n")
        }))

        var details: [String] = []
        if isUniversal {
            details.append(String(localized: "Slice Size") + ": " + FilePresentation.byteLabel(architecture.byteCount))
        }
        if let name = architecture.installName {
            details.append(String(localized: "Install Name") + ": " + name)
        }
        if let platform = inspection.platform {
            details.append(String(localized: "Platform") + ": " + platform)
        }
        if let minimum = inspection.minimumOS {
            details.append(String(localized: "Minimum OS") + ": " + minimum)
        }
        if let sdk = inspection.sdk {
            details.append(String(localized: "SDK") + ": " + sdk)
        }
        if let source = inspection.sourceVersion {
            details.append(String(localized: "Source Version") + ": " + source)
        }
        if let entry = inspection.entryOffset {
            details.append(String(localized: "Entry Offset") + ": " + String(format: "0x%llX", entry))
        }
        if let count = inspection.symbolCount {
            details.append(String(localized: "Symbols") + ": " + String(count))
        }
        if let uuid = architecture.uuid {
            details.append(String(localized: "UUID") + ": " + uuid.uuidString)
        }
        if !inspection.flags.isEmpty {
            details.append(String(localized: "Flags") + ": " + inspection.flags.joined(separator: ", "))
        }
        let encryption = if let method = inspection.encryptionMethod, method != 0 {
            String(
                format: String(localized: "Encrypted, method %u, %@ region"),
                method,
                FilePresentation.byteLabel(Int64(inspection.encryptedByteCount ?? 0))
            )
        } else {
            String(localized: "Not encrypted")
        }
        details.append(String(localized: "Encryption") + ": " + encryption)
        if let identifier = inspection.signingIdentifier {
            details.append(String(localized: "Signing Identifier") + ": " + identifier)
        }
        if let team = inspection.teamIdentifier {
            details.append(String(localized: "Team Identifier") + ": " + team)
        }
        rows.append(.list(String(localized: "Details"), details))
        return rows
    }

    private static func displayValue(_ value: FilaFormats.PropertyListValue) -> PropertyListValue {
        switch value {
        case let .boolean(value): .boolean(value)
        case let .integer(value): .integer(value)
        case let .real(value): .real(value)
        case let .string(value): .string(value)
        case let .date(value): .date(value)
        case let .data(value): .data(value)
        case let .array(values): .array(values.map(displayValue))
        case let .dictionary(values):
            .dictionary(values.keys.sorted().map { (key: $0, value: displayValue(values[$0]!)) })
        }
    }

    private static func fileType(_ value: FilaFormats.MachOImage.FileType?) -> String {
        switch value {
        case .object: String(localized: "Object File")
        case .executable: String(localized: "Executable")
        case .core: String(localized: "Core Dump")
        case .dynamicLibrary: String(localized: "Dynamic Library")
        case .dynamicLinker: String(localized: "Dynamic Linker")
        case .bundle: String(localized: "Bundle")
        case .dynamicLibraryStub: String(localized: "Library Stub")
        case .debugSymbols: String(localized: "Debug Symbols")
        case .kernelExtension: String(localized: "Kernel Extension")
        case .fileSet: String(localized: "File Set")
        case .fixedVMLibrary: String(localized: "Fixed VM Library")
        case .preload: String(localized: "Preload File")
        case nil: String(localized: "Unknown")
        }
    }
}

extension MachOInspectorViewController: UITableViewDelegate {
    func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case let .fact(_, value) = rows[item] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = value
                },
            ])
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch rows[item] {
        case .fact, nil:
            break
        case let .entitlements(value):
            navigationController?.pushViewController(
                PropertyListEditorViewController(title: String(localized: "Entitlements"), value: value),
                animated: true
            )
        case let .list(label, items):
            navigationController?.pushViewController(
                KeyValueListViewController(title: label, rows: items.map { ("", $0) }),
                animated: true
            )
        }
    }
}
