import Darwin
import Dispatch
import FilaProtocol

// MARK: - The child, once it is running

/// The session holder, from the daemon's side: something to reap, and
/// something to hang up.
///
/// This is the daemon's *entire* per-session cost. It holds no descriptor, no
/// buffer and no byte of the stream — the master went to the client and the
/// client pumps it — so a hundred sessions are a hundred pids and a hundred
/// dispatch sources, and a shell printing a gigabyte costs this process
/// nothing. The small session holder owns the controlling terminal and waits
/// for the program; neither it nor the daemon pumps terminal bytes.
public final class TerminalProcess: @unchecked Sendable {
    public let processIdentifier: pid_t

    private let queue = DispatchQueue(label: "wiki.qaq.fila.terminal", qos: .utility)
    private var exitSource: DispatchSourceProcess?
    private var killTimer: DispatchSourceTimer?
    private var hasExited = false

    /// Called once, on a private queue, when the child has been reaped.
    private var onExit: (@Sendable () -> Void)?

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }

    /// Start watching for the child's exit. Every session must call this, or
    /// the daemon accumulates zombies for as long as the app is connected.
    public func watch(onExit: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard exitSource == nil, !hasExited else { return }
            self.onExit = onExit
            let source = DispatchSource.makeProcessSource(
                identifier: processIdentifier,
                eventMask: .exit,
                queue: queue
            )
            // Even a natural leader exit must finish cleaning its owned group.
            // Keep the zombie waitable until the last signal so its PID cannot
            // be recycled underneath a delayed killpg.
            source.setEventHandler { self.beginTermination() }
            exitSource = source
            source.activate()
            // A child may already have exited before source registration.
            var information = siginfo_t()
            var result: Int32
            repeat {
                result = waitid(P_PID, id_t(processIdentifier), &information, WEXITED | WNOHANG | WNOWAIT)
            } while result < 0 && Darwin.errno == EINTR
            if result == 0, information.si_pid == processIdentifier {
                beginTermination()
            } else if result < 0, Darwin.errno == ECHILD {
                settle()
            }
        }
    }

    /// Hang up the original process group, then force it to stop after grace.
    /// Jobs that created another group or detached session are outside this
    /// group's ownership; this is not a whole-session process supervisor.
    public func terminate() {
        queue.async { [self] in beginTermination() }
    }

    private func beginTermination() {
        guard !hasExited, killTimer == nil else { return }
        _ = killpg(processIdentifier, SIGHUP)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + FilaProtocol.terminalHangupGraceSeconds, repeating: .milliseconds(100))
        // Both sources retain this owner until the direct child is reaped. A
        // leader's early exit cannot cancel the group's forced-kill deadline.
        timer.setEventHandler {
            guard !self.hasExited else { return }
            _ = killpg(self.processIdentifier, SIGKILL)
            self.reapIfExited()
        }
        killTimer = timer
        timer.activate()
    }

    private func reapIfExited() {
        guard !hasExited else { return }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(processIdentifier, &status, WNOHANG)
        } while result < 0 && Darwin.errno == EINTR
        // A still-running child keeps this owner alive. Neither an elapsed
        // retry budget nor an unrelated wait error is evidence of completion.
        guard result == processIdentifier || (result < 0 && Darwin.errno == ECHILD) else {
            return
        }
        settle()
    }

    /// Nothing more will be done for this process: drop the sources, and tell
    /// whoever is holding the session that it is over.
    private func settle() {
        guard !hasExited else { return }
        hasExited = true
        exitSource?.cancel()
        exitSource = nil
        killTimer?.cancel()
        killTimer = nil
        let handler = onExit
        onExit = nil
        handler?()
    }
}
