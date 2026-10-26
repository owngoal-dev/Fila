import AlertController
import UIKit

extension UIViewController {
    /// Asks for an absolute path, and hands back the canonical one — the one
    /// prompt behind every *Go to Path…*, so the browser and the tab overview
    /// ask it the same way.
    ///
    /// Canonical as a `fila://` link's path is: a trailing slash or a `.` left
    /// in would name every child so that it never reads as a child, and each
    /// tap below would re-root the tab.
    func promptForPath(initial: String, open: @escaping (String) -> Void) {
        let alert = AlertInputViewController(
            title: String.LocalizationValue("Go to Path"),
            message: String.LocalizationValue("Enter a path starting with a slash."),
            placeholder: String.LocalizationValue("Absolute path"),
            text: initial,
            doneButtonText: String.LocalizationValue("Go"),
            onConfirm: { path in
                guard let path = FilaLink.canonical(path) else { return }
                open(path)
            },
        ).typingLiterally()
        present(alert, animated: true)
    }
}
