import FilaBackendUI
import SnapKit
import Then
import UIKit

/// One extended attribute's value, as text when it is text and as a dump when it
/// is not. Read-only: setting an xattr by hand is possible through
/// `AttributeChange`, but a text field is the wrong instrument for a value whose
/// meaning is a binary layout somebody else defined.
final class AttributeValueViewController: UIViewController {
    private let name: String
    private let value: Data

    init(name: String, value: Data) {
        self.name = name
        self.value = value
        super.init(nibName: nil, bundle: nil)
        title = name
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
            $0.textContainerInset = FilaUI.textContainerInset
            $0.text = String(data: value, encoding: .utf8) ?? Self.dump(value)
        }
        view.addSubview(textView)
        textView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private static func dump(_ data: Data) -> String {
        var lines: [String] = []
        var offset = 0
        // Capped: an xattr can be a resource fork, and a resource fork can be
        // megabytes. The full bytes are a file's worth of content and belong in
        // the hex viewer, not in a `String`.
        while offset < min(data.count, 64 * 1024) {
            let slice = data[data.startIndex + offset ..< data.startIndex + min(offset + 16, data.count)]
            let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
                .padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = String(slice.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  %@ |%@|", offset, hex, ascii))
            offset += 16
        }
        if data.count > 64 * 1024 {
            lines.append("…")
        }
        return lines.joined(separator: "\n")
    }
}
