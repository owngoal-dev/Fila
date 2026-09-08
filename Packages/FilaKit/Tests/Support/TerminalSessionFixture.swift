import Foundation

/// The production C session holder, compiled with a tiny standalone entry point
/// so the host tests need neither the iOS daemon nor a second implementation.
public enum TerminalSessionFixture {
    public static let root = FileManager.default.temporaryDirectory.appendingPathComponent("fila-terminal-tests-" + UUID().uuidString).path
    public static let executable: String = {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CTerminalSession")
        let output = root + "/usr/libexec/filad"
        try! FileManager.default.createDirectory(atPath: root + "/usr/libexec", withIntermediateDirectories: true)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = ["-DFILA_TERMINAL_SESSION_STANDALONE", "-I", source.appendingPathComponent("include").path,
                              source.appendingPathComponent("TerminalSession.c").path, "-o", output]
        do {
            try compiler.run()
            compiler.waitUntilExit()
            precondition(compiler.terminationStatus == 0, "Could not build the production terminal session fixture")
        } catch { preconditionFailure("Could not run clang: \(error)") }
        return output
    }()
}
