// swift-tools-version: 5.9
import PackageDescription

// kishikawakatsumi/SMBClient, vendored. See FILA-VENDOR.md beside this file
// for the pinned revision, the licence and the one change made to it.
let package = Package(
    name: "SMBClient",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
    ],
    products: [
        .library(name: "SMBClient", targets: ["SMBClient"]),
    ],
    targets: [
        .target(name: "SMBClient"),
    ]
)
