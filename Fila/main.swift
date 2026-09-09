import UIKit

// Manual entry point rather than @main: the app is a UIKit shell (the file list
// is a collection view, and will stay one — SwiftUI's List does not survive a
// hundred thousand entries), with SwiftUI used inside individual screens.
MainActor.assumeIsolated {
    // Every bundled backend framework is already mapped by dyld. Discover and
    // register them before UIKit starts, so no screen can ask for a backend
    // the registry does not know about yet.
    BackendComposition.bootstrap()
    _ = UIApplicationMain(
        CommandLine.argc,
        CommandLine.unsafeArgv,
        nil,
        NSStringFromClass(AppDelegate.self)
    )
}
