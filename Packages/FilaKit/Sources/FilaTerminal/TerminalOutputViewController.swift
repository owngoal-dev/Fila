#if canImport(UIKit)
import GhosttyTerminal
import SnapKit
import Then
import UIKit

/// A read-only libghostty surface for the app's own diagnostic output.
/// It owns no PTY, process, or command input.
public final class TerminalOutputViewController: UIViewController {
    public init() {
        super.init(nibName: nil, bundle: nil)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .action, target: self, action: #selector(share)
        )
        navigationItem.rightBarButtonItem?.isEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private let terminalView = OutputView(frame: .zero)
    /// Original lines, without terminal styling or display-width wrapping.
    private var transcript = ""
    private let grid = Grid()
    private lazy var session = InMemoryTerminalSession(write: { _ in }, resize: { [grid] in grid.columns = Int($0.columns) })
    /// The cursor column after the last `append`, so a line appended after a
    /// tag wraps with a hanging indent under its text rather than at column 0.
    private var column = 0
    private let terminalController = TerminalController(
        theme: TerminalAppearance.theme,
        terminalConfiguration: TerminalConfiguration { builder in
            builder.withFontSize(TerminalAppearance.fontSize)
            builder.withCursorStyleBlink(false)
        }
    )

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = TerminalAppearance.background
        terminalView.do {
            $0.controller = terminalController
            $0.configuration = TerminalSurfaceOptions(backend: .inMemory(session), waitAfterCommand: false)
        }
        view.addSubview(terminalView)
        terminalView.snp.makeConstraints { make in
            make.top.bottom.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalToSuperview()
        }
        session.receive("\u{1B}[?25l")
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        terminalView.fitToSize()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        terminalView.setSurfaceVisible(true)
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        terminalView.setSurfaceVisible(false)
    }

    /// SGR parameters. The xterm-256 indices are mid-tones chosen to keep a
    /// contrast ratio of at least 3.4:1 on both Alabaster (#F7F7F7) and
    /// Afterglow (#212121); the pure 16-colour slots are too light on one
    /// theme or too dark on the other.
    public enum TextStyle: String {
        case plain = "0", bold = "1"
        case detail = "38;5;244" // grey #808080
        case heading = "1;38;5;32" // blue #0087D7
        case pass = "38;5;29" // green #00875F
        case passVerdict = "1;38;5;29"
        case fail = "1;38;5;196" // red #FF0000
        case warning = "38;5;166" // orange #D75F00
    }

    /// Appends a line, wrapping it by hand so continuation lines start under
    /// the column the text began at instead of at column 0.
    public func appendLine(_ text: String, style: TextStyle = .plain) {
        let clean = Self.printable(text)
        transcript += clean + "\n"
        let indent = column
        let width = grid.columns
        var lines: [String] = []
        for paragraph in clean.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(paragraph)
            var available = width - indent
            // ponytail: counts characters, not cells, so CJK text wraps a little late.
            while width > 0, available > 0, rest.count > available {
                let limit = rest.index(rest.startIndex, offsetBy: available)
                let cut = rest[..<limit].lastIndex(of: " ").map { rest.index(after: $0) } ?? limit
                lines.append(String(rest[..<cut]))
                rest = rest[cut...].drop { $0 == " " }
                available = width - indent
            }
            lines.append(String(rest))
        }
        render(lines.joined(separator: "\n" + String(repeating: " ", count: indent)), style: style)
        render("\n", style: .plain)
    }

    /// Appends without a newline; a styled span always ends with a reset so the
    /// attributes cannot bleed into whatever is appended next.
    public func append(_ text: String, style: TextStyle = .plain) {
        let clean = Self.printable(text)
        transcript += clean
        render(clean, style: style)
    }

    private static func printable(_ text: String) -> String {
        // Error descriptions are text, never terminal control sequences.
        let printable = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }
        return String(String.UnicodeScalarView(printable))
    }

    private func render(_ clean: String, style: TextStyle) {
        loadViewIfNeeded()
        navigationItem.rightBarButtonItem?.isEnabled = !transcript.isEmpty
        column = clean.lastIndex(of: "\n").map { clean.distance(from: clean.index(after: $0), to: clean.endIndex) } ?? column + clean.count
        let body = clean.replacingOccurrences(of: "\n", with: "\r\n")
        session.receive(style == .plain ? body : "\u{1B}[\(style.rawValue)m" + body + "\u{1B}[0m")
    }

    @objc private func share() {
        guard !transcript.isEmpty, presentedViewController == nil else { return }
        let controller = UIActivityViewController(activityItems: [transcript], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(controller, animated: true)
    }

    private final class Grid: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var columns: Int {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); defer { lock.unlock() }; value = newValue }
        }
    }

    private final class OutputView: TerminalView {
        override var canBecomeFirstResponder: Bool { false }
    }
}
#endif
