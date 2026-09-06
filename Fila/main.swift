import UIKit

// Manual entry point rather than @main: the app is a UIKit shell (the file list
// is a collection view, and will stay one — SwiftUI's List does not survive a
// hundred thousand entries), with SwiftUI used inside individual screens.
_ = UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
