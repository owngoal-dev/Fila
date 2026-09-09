import AlertController
import FilaClient
import FilaFormats
import FilaProtocol
import RunestoneEditor
import SnapKit
import Then
import UIKit

/// Reads a text file. Writes one only when asked to.
///
/// Opening a file gives a **viewer**: the text is selectable, the keyboard
/// never appears, and nothing a finger lands on can change a byte. *Edit*
/// in the file menu turns it into an editor; Save lives in that same menu.
/// That order matters more here than in an ordinary app —
/// this screen writes as root over files that keep the device bootable, so
/// read-only is the correct resting state and the mode has to be legible at a
/// glance rather than inferred from whether a keyboard is up.
///
/// Highlighting is Runestone's, over a tree-sitter grammar chosen by
/// `TextSyntax`; the previous hand-written text view carried a gutter and a
/// find bar of its own and no grammar at all.
///
/// **Large files are refused, not streamed.** A windowed text editor is a text
/// engine — every edit shifts every offset after it, and getting that subtly
/// wrong writes the user's file back scrambled. Above
/// `ViewerLimits.editableTextByteCount` the head is shown with the truncation
/// stated on screen and editing disabled, and the hex viewer opens the rest.
/// That is the honest version of "handles a large file"; the dishonest version
/// is a save button that silently drops the tail.
final class TextViewerViewController: UIViewController {
    private let details: FileDetails
    private let file: DescriptorFile
    private let link: any LocalFileAccess

    let textView = RunestoneEditorView.new()
    let findBar = FindBar()
    private var pendingNotice: String?
    /// A grammar the reader picked by hand for this document, by its name in
    /// `TextSyntax.choices`. Nil means the file's own detection decides.
    private var chosenLanguage: String?

    /// What the bytes decoded as, and what a save re-encodes with. A file that
    /// was not UTF-8 must not become UTF-8 because an editor opened it: Latin-1
    /// round-trips every byte, so an unrecognised encoding at least survives
    /// untouched regions intact.
    private var encoding: String.Encoding = .utf8
    /// The last text known to be on disk. What Cancel restores.
    private var savedText = ""
    private var isTruncated = false
    /// False for a truncated file and for one that could not be read at all.
    private var canEdit = false
    private var isEditingFile = false
    private var isSaving = false
    private var hasUnsavedChanges = false {
        didSet {
            isModalInPresentation = hasUnsavedChanges
            navigationController?.interactivePopGestureRecognizer?.isEnabled = !hasUnsavedChanges
            refreshBarItems()
        }
    }

    private lazy var cancelItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            style: .plain,
            target: self,
            action: #selector(stopEditing)
        )
        item.accessibilityLabel = String(localized: "Cancel")
        return item
    }()

    /// Edit and Save are bar buttons, not menu rows: the mode a page is in
    /// has to be visible without opening anything, and leaving it is one tap.
    private lazy var editItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "pencil"),
            primaryAction: UIAction { [weak self] _ in self?.startEditing() }
        )
        item.accessibilityLabel = String(localized: "Edit")
        return item
    }()

    private lazy var saveItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"),
            primaryAction: UIAction { [weak self] _ in self?.save() }
        )
        item.accessibilityLabel = String(localized: "Save")
        return item
    }()

    init(details: FileDetails, file: DescriptorFile, link: any LocalFileAccess) {
        self.details = details
        self.file = file
        self.link = link
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildInterface()
        loadContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = !hasUnsavedChanges
        (navigationController ?? parent ?? self).presentationController?.delegate = self
        refreshBarItems()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let message = pendingNotice, presentedViewController == nil else { return }
        pendingNotice = nil
        let alert = AlertViewController(title: title ?? details.node.name, message: message) { context in
            context.addAction(title: String.LocalizationValue("Close")) { context.dispose() }
        }
        present(alert, animated: true)
    }

    private func buildInterface() {
        findBar.do {
            $0.isHidden = true
            $0.onFind = { [weak self] term, forwards in self?.find(term, forwards: forwards) }
            $0.onDismiss = { [weak self] in self?.toggleFind() }
        }

        // A file viewer shows the file, not the whitespace inside it; the
        // defaults draw every tab and space as a symbol, and the spell checker
        // underlines every identifier in a config file.
        textView.do {
            $0.showTabs = false
            $0.showSpaces = false
            $0.showNonBreakingSpaces = false
            $0.showLineBreaks = false
            $0.showSoftLineBreaks = false
            $0.spellCheckingType = .no
            $0.lineSelectionDisplayType = .line
            $0.isLineWrappingEnabled = AppPreferences.shared.wrapsLines
            $0.isEditable = false
            $0.editorDelegate = self
        }

        // Hiding the find bar removes its height from the editor.
        let stack = UIStackView(arrangedSubviews: [textView, findBar])
        stack.axis = .vertical
        view.addSubview(stack)

        if #available(iOS 17.0, *) {
            // Keep the editor and its gutter full-height when the keyboard is
            // hidden; scroll-view insets keep the last line above the home bar.
            view.keyboardLayoutGuide.usesBottomSafeArea = false
        }

        // Up to the screen edge, not the safe area: the text view is a scroll
        // view and insets its own content under the bar, which leaves the
        // gutter running the full height behind it instead of stopping short
        // in a white band.
        stack.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }

        // With the gutter running under the bar, the bar needs a background of
        // its own. Before iOS 26 the scroll-edge appearance is transparent, so
        // ask for the blurred material there; iOS 26's scroll edge effect
        // already blurs whatever passes beneath.
        if #unavailable(iOS 26.0) {
            navigationItem.scrollEdgeAppearance = UINavigationBarAppearance().then {
                $0.configureWithDefaultBackground()
            }
        }

        // Presented as a sheet, the pull-to-dismiss gesture is what would
        // discard the edit; `isModalInPresentation` turns that gesture into
        // this callback. The delegate hangs off whichever controller is
        // actually presented — the navigation controller when there is one,
        // otherwise the container this screen is embedded in.
        (navigationController ?? parent ?? self).presentationController?.delegate = self
    }

    private func loadContent() {
        do {
            try PreviewLimits.validate(byteCount: file.byteCount, format: .text)
            let bytes = try file.byteCount > ViewerLimits.editableTextByteCount
                ? file.read(at: 0, count: Int(ViewerLimits.textPreviewByteCount))
                : file.readAll(limit: ViewerLimits.editableTextByteCount)
            let data = Data(bytes.prefix(PreviewLimits.textPrefixByteCount(bytes)))
            isTruncated = data.count < file.byteCount
            let (text, encoding) = Self.decode(data, allowingTruncation: isTruncated)
            self.encoding = encoding
            savedText = text
            canEdit = !isTruncated
            apply(text: text)

            if isTruncated {
                pendingNotice = String(
                    format: String(localized: "Showing the first %@ of %@. This file is too large to edit. Open it as Hex to see the rest."),
                    FilePresentation.byteLabel(Int64(data.count)),
                    FilePresentation.byteLabel(file.byteCount)
                )
            } else if encoding != .utf8 {
                pendingNotice = String(
                    localized: "This file is not valid UTF-8. It is shown and saved without changing the bytes."
                )
            }
        } catch {
            pendingNotice = FailureMessage.text(for: error)
            canEdit = false
        }
        refreshBarItems()
    }

    /// UTF-8 first. A truncated read can cut a multi-byte sequence in half, so a
    /// failure there retreats up to three bytes before giving up — otherwise a
    /// perfectly good file reads as Latin-1 because of where the cut landed.
    private static func decode(_ data: Data, allowingTruncation: Bool) -> (String, String.Encoding) {
        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8)
        }
        if allowingTruncation {
            for trim in 1 ... 3 where data.count > trim {
                if let text = String(data: data.dropLast(trim), encoding: .utf8) {
                    return (text, .utf8)
                }
            }
        }
        // Latin-1 maps every one of the 256 byte values to a character and back
        // again, so it cannot fail and it cannot lose a byte.
        return (String(data: data, encoding: .isoLatin1) ?? "", .isoLatin1)
    }

    // MARK: - Text state and theme

    /// Parses the text and hands it to the view in one go, which is what
    /// `TextViewState` exists for: setting text, theme and language separately
    /// re-parses the whole document once per property.
    private func apply(text: String) {
        let theme = ScaledEditorTheme.theme(for: traitCollection)
        if let language = language(for: text) {
            textView.setState(TextViewState(text: text, theme: theme, language: language))
        } else {
            textView.setState(TextViewState(text: text, theme: theme))
        }
        textView.backgroundColor = theme.backgroundColor
    }

    /// Tree-sitter parses the whole string before the first line is drawn.
    /// Past a point that stall is the only thing the grammar contributes to
    /// a file nobody is reading for its syntax, so past that point there is
    /// no grammar — chosen by hand or not.
    private func language(for text: String) -> TreeSitterLanguage? {
        guard AppPreferences.shared.highlightsSyntax, canHighlight(text) else { return nil }
        if let chosenLanguage {
            return TextSyntax.language(named: chosenLanguage)
        }
        return TextSyntax.language(for: details.path, text: text)
    }

    private func canHighlight(_ text: String) -> Bool {
        text.utf8.count <= ViewerLimits.highlightedTextByteCount
    }

    /// Change only the grammar so toggling colour preserves the document,
    /// its selection, and the editor's undo history.
    private func applyLanguageMode() {
        if let language = language(for: textView.text) {
            textView.setLanguageMode(TreeSitterLanguageMode(language: language))
        } else {
            textView.setLanguageMode(PlainTextLanguageMode())
        }
        refreshBarItems()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        let changed = previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle
            || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
        guard changed else { return }
        // The theme alone, never the state: rebuilding the state here would
        // re-parse the document and throw away the selection every time the
        // system dimmed the screen.
        let theme = ScaledEditorTheme.theme(for: traitCollection)
        textView.theme = theme
        textView.backgroundColor = theme.backgroundColor
    }

    // MARK: - The bar, and the two modes

    private var container: ViewerContainerViewController? {
        parent as? ViewerContainerViewController
    }

    /// This screen's half of the navigation bar. The container copies it onto
    /// the item the bar actually reads, so every change ends with a nudge.
    private func refreshBarItems() {
        let name = URL(fileURLWithPath: details.path).lastPathComponent
        navigationItem.title = name
        cancelItem.isEnabled = !isSaving

        navigationItem.hidesBackButton = isEditingFile
        navigationItem.leftBarButtonItem = isEditingFile ? cancelItem : nil
        saveItem.isEnabled = hasUnsavedChanges && !isSaving
        navigationItem.rightBarButtonItems = isEditingFile ? [saveItem] : (canEdit ? [editItem] : nil)

        container?.childMenuElements = menuElements()
        container?.confirmReplacement = { [weak self] prepareToPresent, replace in
            guard let self, !self.isSaving else { return }
            guard hasUnsavedChanges else {
                leaveEditing()
                replace()
                return
            }
            prepareToPresent()
            confirmDiscarding {
                self.apply(text: self.savedText)
                self.hasUnsavedChanges = false
                self.leaveEditing()
                replace()
            }
        }
        container?.refreshBarItems()
    }

    /// This viewer's own group of the shared menu: find, and the two ways of
    /// looking at text. Both settings are remembered across files.
    private func menuElements() -> [UIMenuElement] {
        let preferences = AppPreferences.shared
        let find = UIAction(
            title: String(localized: "Find"),
            image: UIImage(systemName: "magnifyingglass")
        ) { [weak self] _ in self?.toggleFind() }
        let wrap = UIAction(
            title: String(localized: "Wrap Lines"),
            // `text.word.spacing` is an iOS 16 symbol and draws nothing on 15.
            image: UIImage(systemName: "arrow.turn.down.left"),
            state: preferences.wrapsLines ? .on : .off
        ) { [weak self] _ in
            AppPreferences.shared.wrapsLines.toggle()
            self?.textView.isLineWrappingEnabled = AppPreferences.shared.wrapsLines
            self?.refreshBarItems()
        }
        // The switch, then the grammar: automatic for the file's own detection,
        // or one picked by hand for a file that matches nothing (`.conf`, a log).
        // Picking one turns highlighting on — that is what the tap meant.
        let toggle = UIAction(
            title: String(localized: "Syntax Highlighting"),
            state: preferences.highlightsSyntax ? .on : .off
        ) { [weak self] _ in
            AppPreferences.shared.highlightsSyntax.toggle()
            self?.applyLanguageMode()
        }
        let tooLarge = !canHighlight(textView.text)
        let automatic = UIAction(
            title: String(localized: "Automatic"),
            attributes: tooLarge ? .disabled : [],
            state: chosenLanguage == nil ? .on : .off
        ) { [weak self] _ in
            self?.chosenLanguage = nil
            self?.applyLanguageMode()
        }
        let languages = TextSyntax.choices.map { choice in
            UIAction(
                title: choice.name,
                attributes: tooLarge ? .disabled : [],
                state: chosenLanguage == choice.name ? .on : .off
            ) { [weak self] _ in
                self?.chosenLanguage = choice.name
                AppPreferences.shared.highlightsSyntax = true
                self?.applyLanguageMode()
            }
        }
        let highlight = UIMenu(
            title: String(localized: "Syntax Highlighting"),
            image: UIImage(systemName: "paintbrush"),
            children: [
                toggle,
                UIMenu(
                    title: String(localized: "Language"),
                    options: .displayInline,
                    children: [automatic] + languages
                ),
            ]
        )
        return [find, wrap, highlight]
    }

    private func startEditing() {
        guard canEdit else { return }
        isEditingFile = true
        textView.isEditable = true
        textView.becomeFirstResponder()
        refreshBarItems()
    }

    @objc private func stopEditing() {
        guard !isSaving else { return }
        guard hasUnsavedChanges else { return leaveEditing() }
        confirmDiscarding { [weak self] in
            guard let self else { return }
            apply(text: savedText)
            hasUnsavedChanges = false
            leaveEditing()
        }
    }

    private func leaveEditing() {
        isEditingFile = false
        textView.isEditable = false
        textView.resignFirstResponder()
        refreshBarItems()
    }

    // MARK: - Saving

    private func save() {
        guard canEdit, !isSaving else { return }
        let text = textView.text
        guard let data = text.data(using: encoding) else {
            // Only reachable on a file that decoded as Latin-1: the user typed
            // something outside those 256 values. Refusing out loud, because a
            // Save button that does nothing is indistinguishable from a save.
            presentSaveFailure(ViewerFailure.unsupportedContent(
                String(localized: "Some characters you typed cannot be saved in this file’s encoding. Remove them and try again.")
            ))
            return
        }
        guard data.count <= ViewerLimits.editableTextByteCount else {
            presentSaveFailure(ViewerFailure.tooLarge(
                byteCount: Int64(data.count),
                limit: ViewerLimits.editableTextByteCount
            ))
            return
        }
        isSaving = true
        textView.isEditable = false
        refreshBarItems()
        let path = details.path
        let link = link
        Task { [weak self] in
            do {
                try await AtomicSave.write(data, to: path, link: link)
                await MainActor.run {
                    self?.savedText = text
                    self?.isSaving = false
                    self?.hasUnsavedChanges = false
                    self?.leaveEditing()
                }
            } catch {
                await MainActor.run {
                    // `hasUnsavedChanges` is already true, so its observer will
                    // not fire and Save would stay greyed out on the one screen
                    // where pressing it again is the whole point.
                    self?.isSaving = false
                    self?.textView.isEditable = true
                    self?.hasUnsavedChanges = true
                    self?.refreshBarItems()
                    self?.presentSaveFailure(error)
                }
            }
        }
    }

    // MARK: - Leaving with unsaved changes

    private func confirmDiscarding(_ leave: @escaping () -> Void) {
        guard !isSaving else { return }
        let alert = AlertViewController(
            title: String.LocalizationValue("Unsaved Changes"),
            message: String.LocalizationValue("Leaving now discards what you typed. The file on disk is unchanged.")
        ) { context in
            context.addAction(title: String.LocalizationValue("Cancel")) {
                context.dispose()
            }
            context.addAction(title: String.LocalizationValue("Discard"), attribute: .accent) {
                context.dispose { leave() }
            }
        }
        present(alert, animated: true)
    }

    private func presentSaveFailure(_ error: Error) {
        let alert = AlertViewController(
            title: String(localized: "Unable to Save"),
            message: FailureMessage.text(for: error, whileWriting: true)
        ) { context in
            context.allowSimpleDispose()
            context.addAction(title: String.LocalizationValue("OK"), attribute: .accent) {
                context.dispose()
            }
        }
        present(alert, animated: true)
    }
}

extension TextViewerViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidAttemptToDismiss(_: UIPresentationController) {
        confirmDiscarding { [weak self] in
            guard let self else { return }
            hasUnsavedChanges = false
            dismiss(animated: true)
        }
    }
}

extension TextViewerViewController: TextViewDelegate {
    func textViewDidChange(_: TextView) {
        hasUnsavedChanges = true
    }
}
