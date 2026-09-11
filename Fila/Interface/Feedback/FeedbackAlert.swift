import UIKit

/// Failures outliving their source screen still need a reason and a Close button.
@MainActor
enum FeedbackAlert {
    static func show(_ title: String, message: String) {
        // Let the operation's progress observer dismiss its completed card first.
        DispatchQueue.main.async {
            TopPresenter.whenReady { $0.presentMessage(title, message: message) }
        }
    }
}
