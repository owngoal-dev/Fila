import UIKit

@MainActor
enum FilaMenu {
    static func groups(_ groups: [UIMenuElement]...) -> [UIMenuElement] {
        groups.filter { !$0.isEmpty }.map { UIMenu(options: .displayInline, children: $0) }
    }

    /// Palettes suit a small set of mutually exclusive, recognizable icons.
    /// Keep the same action titles and selection state on older systems.
    static func selection(title: String, actions: [UIAction]) -> UIMenu {
        var options: UIMenu.Options = [.displayInline, .singleSelection]
        if #available(iOS 17.0, *) { options.insert(.displayAsPalette) }
        return UIMenu(title: title, options: options, children: actions)
    }
}
