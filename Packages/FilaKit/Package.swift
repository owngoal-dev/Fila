// swift-tools-version: 6.0
import PackageDescription

// Everything that is not UIKit lives here, for one reason: the code that can
// destroy the user's filesystem has to be testable without a device, without a
// simulator, and without the app. `swift test` in this package is what stands
// between a guard mistake and someone's phone.
//
// The daemon links FilaProtocol + FilaFileOps; the app links FilaProtocol +
// FilaClient + FilaFormats + FilaMedia. Nothing here imports UIKit.
let package = Package(
    name: "FilaKit",
    platforms: [.iOS(.v15), .macOS(.v13), .macCatalyst(.v15)],
    products: [
        .library(name: "FilaProtocol", targets: ["FilaProtocol"]),
        .library(name: "FilaFileOps", type: .static, targets: ["FilaFileOps"]),
        .library(name: "FilaClient", targets: ["FilaClient"]),
        .library(name: "FilaFormats", targets: ["FilaFormats"]),
        .library(name: "FilaLog", targets: ["FilaLog"]),
        .library(name: "FilaMedia", targets: ["FilaMedia"]),
        .library(name: "FilaTerminal", targets: ["FilaTerminal"]),
        .library(name: "FilaRemote", targets: ["FilaRemote"]),
        .library(name: "FilaProvider", type: .static, targets: ["FilaProvider"]),
    ],
    // Dependencies are app-side only. None may reach FilaFileOps or
    // FilaProtocol: those are what the daemon links, and launchd caps the
    // daemon at 6 MB.
    dependencies: [
        // Typed Mach-O structure decoding for the inspector, behind FilaFormats
        // descriptor and size checks; never linked by filad.
        .package(url: "https://github.com/p-x9/MachOKit.git", exact: "0.52.2"),
        // App-side HTTP parser/serializer and Network.framework transport.
        // The DAV adapter still delegates every filesystem decision to the backend.
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.102.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", exact: "1.28.0"),
        // Linked into FilaFormats alone. libarchive reads and writes a dozen
        // formats correctly, including the ones — 7z, rar, iso, xar — that were
        // never going to be hand-written here.
        .package(url: "https://github.com/Lakr233/libarchive.xcframework.git", from: "0.1.1"),
        // The terminal emulator, including host-owned generated configuration
        // storage. Its iOS 15 floor matches this project's deployment target.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.5.20260906"),
        // App-side only, linked by FilaTerminal's UIKit screens. The daemon
        // must never take either: SnapKit and Then are layout and view setup.
        .package(url: "https://github.com/SnapKit/SnapKit.git", from: "6.0.0"),
        .package(url: "https://github.com/devxoul/Then.git", from: "3.0.0"),
    ],
    targets: [
        // The wire vocabulary and the destruction guard. Compiled into both
        // sides, so it must stay free of anything platform-specific beyond XPC.
        .target(name: "FilaProtocol", dependencies: ["CFilaXPC"], swiftSettings: [.swiftLanguageMode(.v5)]),

        // The XPC constants, kept in C so that nothing links the Swift XPC
        // overlay — a dylib iOS 15 does not have. No code, no library: a module
        // map over the SDK's own macros. See `FilaXPC`.
        .systemLibrary(name: "CFilaXPC", path: "Sources/CFilaXPC"),

        // Both sides' log. A fixed-size in-memory ring plus `os_log`, and no
        // dependency past FilaProtocol's wire keys: the daemon links this, and
        // the daemon lives inside launchd's 6 MB jetsam cap. See `FilaLogRing`
        // for the byte ceiling and why it is not a file.
        .target(name: "FilaLog", dependencies: ["FilaProtocol"], swiftSettings: [.swiftLanguageMode(.v5)]),

        // `removefile(3)`'s SDK header, named as a module because the Darwin
        // module does not carry it on every Xcode. No code, no library, no
        // dependency: a module map over a header the SDK already ships.
        .systemLibrary(name: "CRemoveFile", path: "Sources/CRemoveFile"),

        // The root side: POSIX calls and libSystem jobs. The daemon is a
        // dispatcher over this module and holds no file logic of its own,
        // which is what lets the tests reach every destructive path.
        .target(name: "FilaFileOps", dependencies: ["FilaProtocol", "CRemoveFile"], swiftSettings: [.swiftLanguageMode(.v5)]),

        // The app's side of the link: async XPC, one request per call, job
        // events as a stream — and, when there is no daemon to talk to, the
        // same operations run in-process. That second backend is why this
        // depends on FilaFileOps: the app without a daemon calls exactly the
        // code the daemon calls, rather than a second implementation of it.
        //
        // FilaFormats as well, for the in-process backend's archive jobs: with
        // no daemon there is no helper to spawn, so `ArchiveJob` runs here.
        .target(
            name: "FilaClient",
            dependencies: ["FilaProtocol", "FilaLog", "FilaFileOps", "FilaFormats"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Readers and writers that work over a descriptor the daemon handed
        // back: plist, Mach-O, hex, archives. These allocate by content size,
        // which is exactly why they run in the app and never in the daemon —
        // and why `ArchiveJob`, which needs FilaFileOps for the guard and the
        // atomic replace, runs in `fila-archive` rather than in `filad`.
        .target(
            name: "FilaFormats",
            dependencies: [
                "FilaProtocol", "FilaFileOps",
                // The Swift wrapper and its C framework differ only by case.
                // Give the wrapper a distinct module name for Xcode's loader.
                .product(name: "LibArchive", package: "libarchive.xcframework", moduleAliases: ["LibArchive": "FilaLibArchive"]),
                .product(name: "MachOKit", package: "MachOKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // AVFoundation and ImageIO over the same descriptor, for the app only —
        // the daemon must never link this. Both frameworks are told to read
        // through a callback rather than a path, which is the only way a file
        // `mobile` cannot open ever reaches a player or a thumbnail.
        .target(name: "FilaMedia", dependencies: ["FilaFormats"], swiftSettings: [.swiftLanguageMode(.v5)]),

        // The terminal: the pseudo-terminal pump, and the screen libghostty
        // draws it on. The pump is here rather than in the daemon because the
        // daemon must not touch the stream — it opens the pty and hands the
        // master back, the same trade `openPath` makes for a file — and it is
        // here rather than in the app because that is what makes it testable
        // without one. The view controller is behind `#if canImport(UIKit)`, so
        // the module still builds and tests under plain SwiftPM on a Mac.
        .target(
            name: "FilaTerminal",
            dependencies: [
                "FilaProtocol",
                "FilaClient",
                "FilaFileOps",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "SnapKit", package: "SnapKit"),
                .product(name: "Then", package: "Then"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // The network side: a WebDAV server over `NWListener`, and downloading
        // a URL to a path. Linked by the **app only** — never by `filad`, which
        // lives under launchd's 6 MB jetsam cap and has no business holding a
        // listener, a URLSession or an HTTP parser.
        //
        // It depends on FilaProtocol and not on FilaClient: everything it
        // touches goes through `RemoteFileService`, whose one purpose is that
        // `swift test` can exercise a server that publishes the root
        // filesystem without a daemon anywhere in the picture.
        .target(
            name: "FilaRemote",
            dependencies: [
                "FilaProtocol",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .target(name: "FilaProvider", dependencies: ["FilaFileOps", "FilaProtocol"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FilaProviderTests", dependencies: ["FilaProvider"], swiftSettings: [.swiftLanguageMode(.v5)]),

        .testTarget(name: "FilaProtocolTests", dependencies: ["FilaProtocol"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FilaFileOpsTests", dependencies: ["FilaFileOps", "CRemoveFile"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FilaFormatsTests", dependencies: ["FilaFormats", "FilaFileOps"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FilaLogTests", dependencies: ["FilaLog", "FilaProtocol"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FilaMediaTests", dependencies: ["FilaMedia"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FilaClientTests", dependencies: ["FilaClient", "CRemoveFile"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // FilaFileOps as well as FilaRemote: the harness's `RemoteFileService`
        // is the daemon's own file layer with the XPC hop taken out, so the
        // server is exercised against real `copyfile`/`removefile` calls and a
        // real `FilaGuard` rather than against a mock that cannot be wrong.
        .testTarget(
            name: "FilaRemoteTests",
            dependencies: ["FilaRemote", "FilaFileOps", "CRemoveFile", .product(name: "NIOEmbedded", package: "swift-nio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Depends on FilaFileOps so the pump can be driven against a real
        // pseudo-terminal with a real program on it — the same spawn the daemon
        // makes, running as whoever runs the tests.
        .testTarget(
            name: "FilaTerminalTests",
            dependencies: ["FilaTerminal", "FilaFileOps"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
