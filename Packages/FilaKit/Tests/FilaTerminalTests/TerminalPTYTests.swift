import Darwin
import Dispatch
import FilaFileOps
@testable import FilaTerminal
import FilaTestSupport
import Foundation
import Testing

/// The pump, against a real pseudo-terminal with a real program on it.
///
/// The spawn is the daemon's own (`FileOperations.openTerminal`) and the pump is
/// the app's, wired together in one process — which is everything the shipping
/// arrangement does except the XPC hop that carries the master descriptor
/// between them, and the fact that on a device the spawn happens as root.
@Suite("Terminal pump")
struct TerminalPTYTests {
    private var operations: FileOperations {
        _ = TerminalSessionFixture.executable
        return FileOperations(bootstrapRoot: TerminalSessionFixture.root)
    }

    /// Collects what the program prints, and lets a test wait for a marker.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var ended = false

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            text += String(decoding: data, as: UTF8.self)
        }

        func markEnded() {
            lock.lock()
            defer { lock.unlock() }
            ended = true
        }

        var contents: String {
            lock.lock()
            defer { lock.unlock() }
            return text
        }

        var hasEnded: Bool {
            lock.lock()
            defer { lock.unlock() }
            return ended
        }

        func wait(for needle: String, seconds: Double = 10) -> Bool {
            waitUntil(seconds: seconds) { self.contents.contains(needle) }
        }

        func waitForEnd(seconds: Double = 10) -> Bool {
            waitUntil(seconds: seconds) { self.hasEnded }
        }

        private func waitUntil(seconds: Double, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() {
                    return true
                }
                usleep(10000)
            }
            return condition()
        }
    }

    /// A shell on a pty, pumped. Torn down whichever way the test ends.
    private func withShell(_ body: (TerminalPTY, TerminalProcess, Sink) throws -> Void) throws {
        let launch = try operations.openTerminal(TerminalRequest(executable: "/bin/sh", columns: 80, rows: 24))
        let sink = Sink()
        let pty = TerminalPTY(descriptor: launch.descriptor)
        pty.onOutput = { sink.append($0) }
        pty.onEnd = { sink.markEnded() }
        pty.start()
        defer {
            pty.close()
            launch.process.terminate()
        }
        try body(pty, launch.process, sink)
    }

    @Test("bytes travel both ways between the program and the pump")
    func pumpsBothDirections() throws {
        try withShell { pty, _, sink in
            pty.send(Data("printf 'fila-marker\\n'\n".utf8))
            #expect(sink.wait(for: "fila-marker"))
        }
    }

    @Test("a resize reaches the program, which is what SIGWINCH is")
    func resizes() throws {
        try withShell { pty, _, sink in
            // The app owns the master, so this is one `ioctl` with no daemon in
            // it — and the kernel signals the foreground process group itself.
            pty.resize(columns: 132, rows: 40)
            pty.send(Data("stty size\n".utf8))
            #expect(sink.wait(for: "40 132"))
        }
    }

    @Test("a paste larger than the terminal's own buffer arrives whole")
    func deliversALargePaste() throws {
        // A pty master takes about a kilobyte ahead of the reader and answers
        // EAGAIN for the rest, so this is the buffering under test: without it
        // the tail of a paste is silently lost.
        let launch = try operations.openTerminal(TerminalRequest(executable: "/bin/cat"))
        let sink = Sink()
        let pty = TerminalPTY(descriptor: launch.descriptor)
        pty.onOutput = { sink.append($0) }
        pty.onEnd = { sink.markEnded() }
        pty.start()
        defer {
            pty.close()
            launch.process.terminate()
        }

        // Lines, not one long string: a terminal in canonical mode will not
        // take more than `MAX_CANON` before a newline, so a single 40 KB line
        // is a test of the line discipline rather than of this buffer.
        let paste = String(repeating: "0123456789\n", count: 4000) + "END-OF-PASTE\n"
        pty.send(Data(paste.utf8))
        #expect(sink.wait(for: "END-OF-PASTE", seconds: 30))
    }

    @Test("the pump reports the program letting go of the terminal")
    func reportsTheProgramEnding() throws {
        try withShell { pty, _, sink in
            pty.send(Data("exit 0\n".utf8))
            #expect(sink.waitForEnd())
        }
    }

    @Test("closing the master hangs the session up")
    func closingHangsUp() throws {
        // The claim the whole teardown rests on: the app closing its master is
        // what revokes the terminal, and the kernel sends SIGHUP to the
        // session. The daemon's kill is the belt to this braces, for a program
        // that ignores the signal.
        let launch = try operations.openTerminal(TerminalRequest(executable: "/bin/sh"))
        let pty = TerminalPTY(descriptor: launch.descriptor)
        pty.start()

        let ended = DispatchSemaphore(value: 0)
        launch.process.watch { ended.signal() }
        pty.close()
        #expect(ended.wait(timeout: .now() + 10) == .success)
    }
}
