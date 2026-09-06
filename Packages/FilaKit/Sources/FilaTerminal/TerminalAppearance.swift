#if canImport(UIKit)
import GhosttyTerminal
import UIKit

/// One background value for libghostty and for the UIKit view around it, so the
/// safe areas and the bar are the same colour as the terminal surface.
enum TerminalAppearance {
    static let fontSize: Float = 10

    /// Alabaster's and Afterglow's own backgrounds, restated because the library
    /// gives no way to read them back out of a configuration.
    private static let light: UInt8 = 0xF7
    private static let dark: UInt8 = 0x21

    static let theme = TerminalTheme(
        light: .alabaster.background(hex(light)),
        dark: .afterglow.background(hex(dark))
    )

    static let background = UIColor { traits in
        UIColor(white: CGFloat(traits.userInterfaceStyle == .dark ? dark : light) / 255, alpha: 1)
    }

    private static func hex(_ white: UInt8) -> String {
        String(format: "%02X%02X%02X", white, white, white)
    }
}
#endif
