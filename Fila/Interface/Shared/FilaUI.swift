import Then
import UIKit

/// Shared measurements for custom UIKit content. Native text styles, list
/// margins and semantic colors remain owned by UIKit.
enum FilaUI {
    enum Spacing {
        static let compact: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let extraLarge: CGFloat = 24
    }

    static let minimumTapTarget: CGFloat = 44

    enum IconSize {
        static let file: CGFloat = 30
        static let inline: CGFloat = 22
        /// A status card's artwork: the sharing folder, an app's icon.
        static let hero: CGFloat = 64
    }

    enum Font {
        static let monospacedBodySize: CGFloat = 15

        static var monospacedBody: UIFont {
            UIFontMetrics(forTextStyle: .body)
                .scaledFont(for: .monospacedSystemFont(ofSize: monospacedBodySize, weight: .regular))
        }

        static var monospacedValue: UIFont {
            UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 16, weight: .regular))
        }

        static var monospacedFootnote: UIFont {
            UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        }
    }

    static var textContainerInset: UIEdgeInsets {
        UIEdgeInsets(top: Spacing.large, left: Spacing.medium, bottom: Spacing.large, right: Spacing.medium)
    }
}

extension String.LocalizationValue {
    /// A text field that shows no placeholder, for the fields that arrive with
    /// their value already in them.
    ///
    /// Written as a value and not as `""` at the call site. Xcode extracts
    /// every literal in a `String.LocalizationValue` position, so an empty
    /// literal puts an empty key in the string catalogue — and puts it back on
    /// the next build after anyone deletes it.
    static let noPlaceholder = String.LocalizationValue(String())
}

extension UIListContentConfiguration: @retroactive Then {}
extension UIButton.Configuration: @retroactive Then {}
extension UICollectionLayoutListConfiguration: @retroactive Then {}
