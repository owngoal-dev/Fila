import AlertController
import FilaClient
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
    private let link: DaemonLink

    private let textView = RunestoneEditorView.new()
    private let findBar = FindBar()
    private let notice = UILabel()
    /// Holds the stack under the bar while the notice is showing; inactive
    /// otherwise, so the editor and its gutter run up under the bar.
    private var noticeBelowBar: Constraint?
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
        let item = UIBarButtonItem(image: UIImage(systemName: "xmark"), style: .plain, target: self, action: #selector(stopEditing))
        item.accessibilityLabel = String(localized: "Cancel")
        return item
    }()

    // Edit and Save are bar buttons, not menu rows: the mode a page is in
    // has to be visible without opening anything, and leaving it is one tap.
    private lazy var editItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "pencil"), primaryAction: UIAction { [weak self] _ in self?.startEditing() })
        item.accessibilityLabel = String(localized: "Edit")
        return item
    }()

    private lazy var saveItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "checkmark"), primaryAction: UIAction { [weak self] _ in self?.save() })
        item.accessibilityLabel = String(localized: "Save")
        return item
    }()

    init(details: FileDetails, file: DescriptorFile, link: DaemonLink) {
        self.details = details
        self.file = file
        self.link = link
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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

    private func buildInterface() {
        notice.do {
            $0.font = .preferredFont(forTextStyle: .footnote)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = .secondaryLabel
            $0.numberOfLines = 0
            $0.textAlignment = .center
            $0.backgroundColor = .secondarySystemBackground
            $0.isHidden = true
        }

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

        // A stack, so that hiding the notice or the find bar takes their height
        // with them: a hidden view still occupies its constraints, and the
        // usual case here is both of them hidden.
        let stack = UIStackView(arrangedSubviews: [notice, textView, findBar])
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
        // in a white band. Only a notice needs to start below the bar.
        stack.snp.makeConstraints { make in
            make.top.equalToSuperview().priority(.high)
            noticeBelowBar = make.top.equalTo(view.safeAreaLayoutGuide).constraint
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }
        noticeBelowBar?.deactivate()

        // With the gutter running under the bar, the bar needs a background of
        // its own. Before iOS 26 the scroll-edge appearance is transparent, so
        // ask for the blurred material there; iOS 26's scroll edge effect
        // already blurs whatever passes beneath.
        if #unavailable(iOS 26.0) {
            navigationItem.scrollEdgeAppearance = UINavigationBarAppearance().then { $0.configureWithDefaultBackground() }
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
            let budget = min(file.byteCount, ViewerLimits.editableTextByteCount)
            isTruncated = file.byteCount > ViewerLimits.editableTextByteCount
            let limit = isTruncated ? ViewerLimits.textPreviewByteCount : budget
            let data = try isTruncated
                ? file.read(at: 0, count: Int(limit))
                : file.readAll(limit: ViewerLimits.editableTextByteCount)
            let (text, encoding) = Self.decode(data, allowingTruncation: isTruncated)
            self.encoding = encoding
            savedText = text
            canEdit = !isTruncated
            apply(text: text)

            if isTruncated {
                showNotice(String(
                    format: String(localized: "Showing the first %@ of %@. This file is too large to edit. Open it as Hex to see the rest."),
                    FilePresentation.byteLabel(limit),
                    FilePresentation.byteLabel(file.byteCount)
                ))
                notice.layoutIfNeeded()
            } else if encoding != .utf8 {
                showNotice(String(localized: "This file is not valid UTF-8. It is shown and saved without changing the bytes."))
            }
        } catch {
            showNotice(FailureMessage.text(for: error))
            canEdit = false
        }
        refreshBarItems()
    }

    private func showNotice(_ text: String) {
        notice.text = text
        notice.isHidden = false
        noticeBelowBar?.activate()
    }

    /// UTF-8 first. A truncated read can cut a multi-byte sequence in half, so a
    /// failure there retreats up to three bytes before giving up — otherwise a
    /// perfectly good file reads as Latin-1 because of where the cut landed.
    private static func decode(_ data: Data, allowingTruncation: Bool) -> (String, String.Encoding) {
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        if allowingTruncation {
            for trim in 1 ... 3 where data.count > trim {
                if let text = String(data: data.dropLast(trim), encoding: .utf8) { return (text, .utf8) }
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
        if let chosenLanguage { return TextSyntax.language(named: chosenLanguage) }
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

    private var container: ViewerContainerViewController? { parent as? ViewerContainerViewController }

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
        container?.confirmReplacement = { [weak self] replace in
            guard let self, !self.isSaving else { return }
            guard self.hasUnsavedChanges else {
                self.leaveEditing()
                replace()
                return
            }
            self.confirmDiscarding {
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
            image: UIImage(systemName: "text.word.spacing"),
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
                UIMenu(title: String(localized: "Language"), options: .displayInline, children: [automatic] + languages),
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
            self.apply(text: self.savedText)
            self.hasUnsavedChanges = false
            self.leaveEditing()
        }
    }

    private func leaveEditing() {
        isEditingFile = false
        textView.isEditable = false
        textView.resignFirstResponder()
        refreshBarItems()
    }

    // MARK: - Saving

    /// `then` runs only if the write actually succeeded — it is how "Save"
    /// in the leaving confirmation gets to leave. A failed save must keep the
    /// editor on screen with the text still in it, because the text is now the
    /// only copy.
    private func save(then continuation: (() -> Void)? = nil) {
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
                    continuation?()
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
            title: "Unsaved Changes",
            message: "Leaving now discards what you typed. The file on disk is unchanged."
        ) { [weak self] context in
            context.addAction(title: "Cancel") {
                context.dispose()
            }
            context.addAction(title: "Save", attribute: .accent) {
                context.dispose { self?.save(then: leave) }
            }
            context.addAction(title: "Discard Changes", attribute: .accent) {
                context.dispose { leave() }
            }
        }
        present(alert, animated: true)
    }

    private func presentSaveFailure(_ error: Error) {
        let alert = AlertViewController(
            title: "Unable to Save",
            message: FailureMessage.text(for: error, whileWriting: true)
        ) { context in
            context.allowSimpleDispose()
            context.addAction(title: "OK", attribute: .accent) {
                context.dispose()
            }
        }
        present(alert, animated: true)
    }

    // MARK: - Find

    private func toggleFind() {
        findBar.isHidden.toggle()
        if findBar.isHidden {
            findBar.endEditing(true)
        } else {
            findBar.becomeFirstResponderOnField()
        }
    }

    private func find(_ term: String, forwards: Bool) {
        guard !term.isEmpty else { return findBar.showResult(nil) }
        let text = textView.text as NSString
        let selection = textView.selectedRange
        var first: NSRange?
        var last: NSRange?
        var target: NSRange?
        var count = 0
        var current = 0
        var position = 0
        while position < text.length {
            let match = text.range(of: term, options: [.caseInsensitive], range: NSRange(location: position, length: text.length - position))
            guard match.location != NSNotFound, match.length > 0 else { break }
            count += 1
            if first == nil { first = match }
            last = match
            if forwards ? target == nil && match.location >= NSMaxRange(selection) : NSMaxRange(match) <= selection.location {
                target = match
                current = count
            }
            position = NSMaxRange(match)
        }
        guard let first, let last else {
            findBar.showResult(String(localized: "No results"))
            return
        }
        if target == nil {
            target = forwards ? first : last
            current = forwards ? 1 : count
        }
        guard let target else { return }
        textView.selectedRange = target
        textView.scrollRangeToVisible(target)
        findBar.showResult(String(format: String(localized: "%lld of %lld"), Int64(current), Int64(count)))
    }
}

extension TextViewerViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidAttemptToDismiss(_ controller: UIPresentationController) {
        confirmDiscarding { [weak self] in
            guard let self else { return }
            self.hasUnsavedChanges = false
            self.dismiss(animated: true)
        }
    }
}

extension TextViewerViewController: TextViewDelegate {
    func textViewDidChange(_ textView: TextView) {
        hasUnsavedChanges = true
    }
}

/// A find bar. iOS 16 has `UIFindInteraction` and this becomes four lines the
/// day the deployment target moves; until then it is a text field and two
/// chevrons.
final class FindBar: UIView {
    var onFind: ((String, Bool) -> Void)?
    var onDismiss: (() -> Void)?

    private let field = UITextField()
    private let result = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground

        field.do {
            $0.placeholder = String(localized: "Find")
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.borderStyle = .roundedRect
            $0.autocorrectionType = .no
            $0.autocapitalizationType = .none
            $0.returnKeyType = .search
            $0.setContentHuggingPriority(UILayoutPriority(249), for: .horizontal)
            $0.addTarget(self, action: #selector(findNext), for: .editingDidEndOnExit)
        }

        let backward = UIButton(type: .system).then {
            $0.setImage(UIImage(systemName: "chevron.up"), for: .normal)
            $0.accessibilityLabel = String(localized: "Find Previous")
            $0.addTarget(self, action: #selector(findPrevious), for: .touchUpInside)
        }

        let forward = UIButton(type: .system).then {
            $0.setImage(UIImage(systemName: "chevron.down"), for: .normal)
            $0.accessibilityLabel = String(localized: "Find Next")
            $0.addTarget(self, action: #selector(findNext), for: .touchUpInside)
        }

        let done = UIButton(type: .system).then {
            $0.setTitle(String(localized: "Done"), for: .normal)
            $0.addTarget(self, action: #selector(dismiss), for: .touchUpInside)
        }

        let controls = UIStackView(arrangedSubviews: [field, backward, forward, done]).then {
            $0.spacing = FilaUI.Spacing.compact
            $0.alignment = .center
        }
        result.do {
            $0.font = .preferredFont(forTextStyle: .caption1)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = .secondaryLabel
            $0.textAlignment = .center
            $0.isHidden = true
        }
        let stack = UIStackView(arrangedSubviews: [controls, result]).then {
            $0.axis = .vertical
            $0.spacing = FilaUI.Spacing.compact
        }
        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.leading.trailing.equalTo(layoutMarginsGuide)
            make.top.equalToSuperview().offset(FilaUI.Spacing.small)
            make.bottom.equalTo(safeAreaLayoutGuide).offset(-FilaUI.Spacing.small).priority(.high)
        }
        backward.snp.makeConstraints { make in
            make.width.equalTo(FilaUI.minimumTapTarget)
            make.height.greaterThanOrEqualTo(FilaUI.minimumTapTarget)
        }
        forward.snp.makeConstraints { make in
            make.width.equalTo(FilaUI.minimumTapTarget)
            make.height.greaterThanOrEqualTo(FilaUI.minimumTapTarget)
        }
        done.snp.makeConstraints { make in
            make.size.greaterThanOrEqualTo(FilaUI.minimumTapTarget)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func becomeFirstResponderOnField() { field.becomeFirstResponder() }

    func showResult(_ text: String?) {
        result.text = text
        result.isHidden = text == nil
    }

    @objc private func findNext() { onFind?(field.text ?? "", true) }
    @objc private func findPrevious() { onFind?(field.text ?? "", false) }
    @objc private func dismiss() { onDismiss?() }
}
