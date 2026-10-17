#if canImport(UIKit)
    import SnapKit
    import Then
    import UIKit

    /// One labelled text field in a grouped row: the title leading, the value
    /// typed trailing, the way Settings lays out a form. Shared by every
    /// module's connection setup.
    public final class FormFieldCell: UITableViewCell {
        public struct Configuration {
            public var title: String
            public var placeholder: String
            public var text: String
            public var keyboard: UIKeyboardType
            public var isSecure: Bool

            public init(title: String, placeholder: String, text: String, keyboard: UIKeyboardType = .default, isSecure: Bool = false) {
                self.title = title
                self.placeholder = placeholder
                self.text = text
                self.keyboard = keyboard
                self.isSecure = isSecure
            }
        }

        private let titleLabel = UILabel().then {
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        private let field = UITextField().then {
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.textAlignment = .right
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.spellCheckingType = .no
            $0.smartQuotesType = .no
            $0.smartDashesType = .no
            $0.smartInsertDeleteType = .no
            $0.clearButtonMode = .whileEditing
            $0.returnKeyType = .done
        }

        private var onChange: ((String) -> Void)?

        override public init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            selectionStyle = .none
            field.addTarget(self, action: #selector(changed), for: .editingChanged)
            field.addTarget(self, action: #selector(finishTextEntry(_:)), for: .editingDidEndOnExit)
            let row = UIStackView(arrangedSubviews: [titleLabel, field]).then {
                $0.axis = .horizontal
                $0.alignment = .center
                $0.spacing = FilaUI.Spacing.large
            }
            contentView.addSubview(row)
            row.snp.makeConstraints { make in
                make.edges.equalTo(contentView.layoutMarginsGuide)
                make.height.greaterThanOrEqualTo(FilaUI.minimumTapTarget - 2 * FilaUI.Spacing.small)
            }
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        public func configure(_ configuration: Configuration, onChange: @escaping (String) -> Void) {
            titleLabel.text = configuration.title
            field.do {
                $0.text = configuration.text
                $0.placeholder = configuration.placeholder
                $0.accessibilityLabel = configuration.title
                $0.keyboardType = configuration.keyboard
                $0.isSecureTextEntry = configuration.isSecure
                $0.textContentType = configuration.isSecure ? .password : nil
            }
            self.onChange = onChange
        }

        public func beginEditing() {
            field.becomeFirstResponder()
        }

        /// A placeholder that changes under a live field, without a reload that
        /// would take the keyboard away.
        public func setPlaceholder(_ placeholder: String) {
            field.placeholder = placeholder
        }

        @objc private func changed() {
            onChange?(field.text ?? "")
        }

        @objc private func finishTextEntry(_ sender: UITextField) {
            sender.resignFirstResponder()
        }
    }
#endif
