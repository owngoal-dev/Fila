#if canImport(UIKit)
import Then
import UIKit

/// Shared measurements for custom UIKit content. Native text styles, list
/// margins and semantic colors remain owned by UIKit.
public enum FilaUI {
    public enum Spacing {
        public static let compact: CGFloat = 4
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 16
    }

    public static let minimumTapTarget: CGFloat = 44

    /// Every form sheet the app presents is this one size — settings, a
    /// server's setup, the compress form, a picker — so sheets do not
    /// step between sizes as one replaces another. Compact widths ignore
    /// it and take the whole width as they always did.
    public static let formSheetSize = CGSize(width: 555, height: 555)

    public enum IconSize {
        public static let file: CGFloat = 30
        public static let inline: CGFloat = 22
        /// A status card's artwork: the sharing folder, an app's icon.
        public static let hero: CGFloat = 64
    }

    public enum Font {
        public static let monospacedBodySize: CGFloat = 15

        public static var monospacedBody: UIFont {
            UIFontMetrics(forTextStyle: .body)
                .scaledFont(for: .monospacedSystemFont(ofSize: monospacedBodySize, weight: .regular))
        }

        public static var monospacedValue: UIFont {
            UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 16, weight: .regular))
        }

        public static var monospacedFootnote: UIFont {
            UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        }
    }

    public static var textContainerInset: UIEdgeInsets {
        UIEdgeInsets(top: Spacing.large, left: Spacing.medium, bottom: Spacing.large, right: Spacing.medium)
    }
}

public extension String.LocalizationValue {
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
#endif
