@testable import FilaRemote
import Foundation
import Testing

/// Not a test. `FILA_WEB_DEMO=1 swift test --filter WebUIDemo` serves a
/// scratch directory over the real server, with the frontend read live from
/// `WebUI/dist` (run `npm run watch` there and reload), so the web UI can be
/// looked at in a browser on the Mac. Skipped in a normal run.
@Suite("Web UI demo")
struct WebUIDemo {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FILA_WEB_DEMO"] != nil))
    func serve() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent() // Tests/FilaRemoteTests
            .deletingLastPathComponent().deletingLastPathComponent() // Packages/FilaKit
            .deletingLastPathComponent().deletingLastPathComponent()
        let dist = repository.appendingPathComponent("WebUI/dist").path
        let harness = try await Harness(webRoot: dist)
        let scratch = harness.scratch
        scratch.directory("Documents")
        scratch.directory("Photos")
        scratch.file("Documents/notes.txt", contents: "hello from fila\n")
        scratch.file("Documents/config.plist", contents: "<plist/>")
        scratch.file("Photos/IMG_0001.HEIC", contents: String(repeating: "x", count: 300_000))
        scratch.file("README.md", contents: "# Fila\n")
        print("""

        ===== Fila Web UI =====
        URL:      http://127.0.0.1:\(harness.port)/
        user:     \(harness.user)
        password: \(harness.password)
        root:     \(scratch.root)
        web root: \(dist)
        Ctrl-C to stop.
        =======================

        """)
        fflush(stdout)
        try await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
    }
}
