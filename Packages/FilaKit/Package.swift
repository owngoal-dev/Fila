// swift-tools-version: 6.0
import PackageDescription

/// Everything that is not UIKit lives here, for one reason: the code that can
/// destroy the user's filesystem has to be testable without a device, without a
/// simulator, and without the app. `swift test` in this package is what stands
/// between a guard mistake and someone's phone.
///
/// The daemon links FilaProtocol + FilaFileOps; the app links FilaProtocol +
/// FilaClient + FilaFormats + FilaMedia. Nothing here imports UIKit.
let package = Package(
    name: "FilaKit",
    // A target that shows the user a sentence owns its own catalogue: Xcode's
    // extractor only walks the app target, so a `String(localized:)` here is
    // invisible to it and an app-catalogue entry for it is pruned as stale.
    defaultLocalization: "en",
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
        .library(name: "FilaBackendKit", targets: ["FilaBackendKit"]),
        .library(name: "FilaBackendUI", targets: ["FilaBackendUI"]),
        .library(name: "CFilaMusicLibrary", type: .static, targets: ["CFilaMusicLibrary"]),
    ],
    // Dependencies are app-side only. None may reach FilaFileOps or
    // FilaProtocol: those are what the daemon links, and launchd caps the
    // daemon at 6 MB.
    dependencies: [
        // Typed Mach-O structure decoding for the inspector, behind FilaFormats
        // descriptor and size checks; never linked by filad.
        .package(url: "https://github.com/p-x9/MachOKit.git", from: "0.52.2"),
        // App-side HTTP parser/serializer and Network.framework transport.
        // The DAV adapter still delegates every filesystem decision to the backend.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.102.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.28.0"),
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
        // The SMB2 client, vendored at a pinned revision with one paging
        // method added; see Packages/SMBClient/FILA-VENDOR.md. Linked by
        // FilaSMB alone, which is app-side in both compositions.
        .package(path: "../SMBClient"),
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
        .target(name: "CTerminalSession"),
        .target(
            name: "FilaFileOps",
            dependencies: ["FilaProtocol", "CRemoveFile", "CTerminalSession"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // The local file contract and its in-process answer: `LocalFileAccess`,
        // `LocalFileService` running the daemon's own operations in this
        // process, and `LocalFileBackend` presenting a local root through the
        // backend-neutral contract. It depends on FilaFileOps because the app
        // without a daemon calls exactly the code the daemon calls, rather
        // than a second implementation of it, and on FilaFormats for the
        // in-process backend's archive jobs: with no daemon there is no
        // helper to spawn, so `ArchiveJob` runs here. The XPC side is
        // `FilaPrivileged`, below, which depends on this and never the
        // other way round.
        .target(
            name: "FilaClient",
            dependencies: ["FilaProtocol", "FilaLog", "FilaFileOps", "FilaFormats", "FilaBackendKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // The privileged side of the local contract: `DaemonLink`, which
        // sends every request to `filad` over XPC and falls back to the
        // in-process service when no daemon was installed, and the only
        // implementation of `TerminalAccess`.
        //
        // Deliberately **not a product**. Xcode links a package product's
        // whole closure into every target that consumes it, so a product
        // here would put a second copy of FilaClient, FilaProtocol and
        // FilaLog into `FilaPrivileged.framework` beside the one in
        // FilaCore. Instead the framework compiles this directory itself,
        // and the target here exists for `swift test` alone.
        //
        // The framework ships in every wrapper of the full app and is a
        // required load command there (`-needed_framework`): stripping it
        // from a product that was linked with it aborts in dyld. The
        // sandboxed composition is a separate app target that never links
        // it, not a packaging step that removes it.
        .target(
            name: "FilaPrivileged",
            dependencies: ["FilaClient", "FilaProtocol", "FilaLog"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FilaPrivilegedTests",
            dependencies: ["FilaPrivileged", "FilaClient", "CRemoveFile"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // The installed-applications catalogue: LaunchServices behind a
        // runtime lookup, the bundle-container scan through the local file
        // contract, the app-folder decorations and the IPA installer. Like
        // FilaPrivileged, **not a product**: `FilaApplications.framework`
        // compiles this directory itself, the sandboxed composition never
        // links that framework, and the target here is for `swift test`.
        .target(
            name: "FilaApplications",
            dependencies: ["FilaBackendKit", "FilaClient", "FilaFormats", "FilaLog", "FilaProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FilaApplicationsTests",
            dependencies: ["FilaApplications", "FilaClient", "CRemoveFile"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // The music library: the Objective-C bridge that owns every private
        // MediaLibrary call so its exceptions never unwind Swift, and the
        // Swift editor over it. The bridge is a product because it has no
        // dependency of its own to duplicate; the Swift target is not, for
        // the same reason as FilaApplications, and its iOS-only parts are
        // behind `os(iOS)` so the host still builds and tests the rest.
        .target(name: "CFilaMusicLibrary", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .target(
            name: "FilaMusicLibrary",
            dependencies: ["CFilaMusicLibrary", "FilaBackendKit", "FilaClient", "FilaLog", "FilaMedia", "FilaProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FilaMusicLibraryTests",
            dependencies: ["FilaMusicLibrary"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // One saved SMB share as a file backend: the profile, the session
        // that serialises every request and retires itself on a timeout,
        // the paged listing and the bounded read into a descriptor. Like
        // FilaApplications, **not a product**: `FilaSMB.framework` compiles
        // this directory itself and is embedded by both compositions; the
        // target here is for `swift test`, which can run it against a real
        // server named by `FILA_SMB_SERVER`.
        .target(
            name: "FilaSMB",
            dependencies: [
                "FilaBackendKit",
                "FilaLog",
                .product(name: "SMBClient", package: "SMBClient"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // FilaClient as well: the live suite carries files between a local
        // root and the share through `FileTransfer`, both ends real.
        .testTarget(
            name: "FilaSMBTests",
            dependencies: ["FilaSMB", "FilaBackendKit", "FilaClient"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Readers and writers that work over a descriptor the daemon handed
        // back: plist, Mach-O, hex, archives. These allocate by content size,
        // which is exactly why they run in the app and never in the daemon —
        // and why `ArchiveJob`, which needs FilaFileOps for the guard and the
        // atomic replace, runs in `fila-archive` rather than in `filad`.
        // Darwin's thread-local locale API is omitted from its Swift overlay.
        .systemLibrary(name: "CArchiveLocale", path: "Sources/CArchiveLocale"),
        .target(
            name: "FilaFormats",
            dependencies: [
                "CArchiveLocale",
                "FilaProtocol", "FilaFileOps",
                // The Swift wrapper and its C framework differ only by case.
                // Give the wrapper a distinct module name for Xcode's loader.
                .product(
                    name: "LibArchive",
                    package: "libarchive.xcframework",
                    moduleAliases: ["LibArchive": "FilaLibArchive"]
                ),
                .product(name: "MachOKit", package: "MachOKit"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // AVFoundation and ImageIO over the same descriptor, for the app only —
        // the daemon must never link this. Both frameworks are told to read
        // through a callback rather than a path, which is the only way a file
        // `mobile` cannot open ever reaches a player or a thumbnail.
        .target(
            name: "FilaMedia",
            dependencies: ["FilaFormats"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

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
                "FilaBackendUI",
                "FilaClient",
                "FilaFileOps",
                "FilaLog",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "SnapKit", package: "SnapKit"),
                .product(name: "Then", package: "Then"),
            ],
            resources: [.process("Resources")],
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
                "FilaFileOps", // Shared descriptor-based storage reserve checks.
                "FilaLog", // Connection lines land on the same timeline as everything else.
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(
            name: "FilaProtocolTests",
            dependencies: ["FilaProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The backend module contract: entry class, registration, registry
        // and the values a backend and the shell exchange. Foundation only,
        // so a module framework can depend on it without XPC, UIKit or a
        // vendor library, and it is linked into the process exactly once
        // through FilaCore.framework.
        .target(name: "FilaBackendKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "FilaBackendKitTests",
            dependencies: ["FilaBackendKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The shared list screen every backend's root is shown with, the
        // status panel and the layout tokens. UIKit, behind `canImport`, so
        // the package still builds on the Mac; linked once, through FilaCore,
        // and used by the app and every module framework alike.
        .target(
            name: "FilaBackendUI",
            dependencies: [
                "FilaBackendKit",
                "FilaLog",
                .product(name: "SnapKit", package: "SnapKit"),
                .product(name: "Then", package: "Then"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .target(name: "FilaTestSupport", path: "Tests/Support", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "FilaFileOpsTests",
            dependencies: ["FilaFileOps", "CRemoveFile", "FilaTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FilaFormatsTests",
            dependencies: ["FilaFormats", "FilaFileOps"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FilaLogTests",
            dependencies: ["FilaLog", "FilaProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "FilaMediaTests", dependencies: ["FilaMedia"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "FilaClientTests",
            dependencies: ["FilaClient", "CRemoveFile"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // FilaFileOps as well as FilaRemote: the harness's `RemoteFileService`
        // is the daemon's own file layer with the XPC hop taken out, so the
        // server is exercised against real `copyfile`/`removefile` calls and a
        // real `FilaGuard` rather than against a mock that cannot be wrong.
        .testTarget(
            name: "FilaRemoteTests",
            dependencies: [
                "FilaRemote",
                "FilaFileOps",
                "CRemoveFile",
                .product(name: "NIOEmbedded", package: "swift-nio")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Depends on FilaFileOps so the pump can be driven against a real
        // pseudo-terminal with a real program on it — the same spawn the daemon
        // makes, running as whoever runs the tests.
        .testTarget(
            name: "FilaTerminalTests",
            dependencies: ["FilaTestSupport", "FilaTerminal", "FilaFileOps"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
