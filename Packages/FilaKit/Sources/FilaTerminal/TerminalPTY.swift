import Darwin
import Dispatch
import Foundation

/// The pseudo-terminal pump, on the app's side of the link.
///
/// **This is where the terminal's bytes live, and putting them here is the
/// whole design.** `filad` opened the pty and exec'd on it, then handed the
/// master descriptor over XPC and closed its own copy — so the stream flows
/// between this process and the kernel with nothing in between, exactly the way
/// file contents already do. The daemon keeps a pid and a dispatch source per
/// session and not one byte, which is why `filad` stays flat under launchd's
/// 6 MB jetsam cap without the second process `ighostvtd` has to spawn for the
/// same job.
///
/// Everything here runs on one private serial queue, and output is handed to
/// the caller on it: `InMemoryTerminalSession.receive` is thread-safe and
/// parses on a queue of its own, so a shell printing hard never touches the
/// main thread.
public final class TerminalPTY: @unchecked Sendable {
    /// One read of the master. Bigger than a pty's own buffer, so a busy shell
    /// costs one syscall per wake rather than one per kilobyte.
    private static let readByteCount = 64 * 1024

    /// Input the kernel has not taken yet, ceiling.
    ///
    /// A pty master accepts about a kilobyte ahead of whatever is reading the
    /// terminal (XNU's `TTYHOG`) and answers `EAGAIN` for the rest — and a
    /// paste is one write of everything. Past this the program is not reading
    /// its terminal at all; refusing the paste whole beats delivering half of
    /// it, which is how a bracketed paste loses its terminator and leaves the
    /// program stuck in paste mode.
    private static let pendingInputLimit = 1 << 20

    private let descriptor: Int32
    private let queue = DispatchQueue(label: "wiki.qaq.fila.pty", qos: .userInitiated)
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    /// Sources still holding the descriptor. It may not be closed until every
    /// one of them has run its cancel handler, so the last one out closes it.
    private var liveSourceCount = 0
    private var isWriteSourceRunning = false
    private var isClosed = false
    private var hasEnded = false

    /// Input the kernel would not take, and how much of it is already gone.
    /// An index rather than `removeFirst`, which would recopy the tail of a
    /// megabyte paste for every kilobyte the program consumes.
    private var pending = Data()
    private var pendingOffset = 0

    /// Bytes the program printed, on the pump's own queue.
    public var onOutput: (@Sendable (Data) -> Void)?
    /// The program let go of the terminal — it exited, or was hung up. Called
    /// at most once, on the pump's own queue.
    public var onEnd: (@Sendable () -> Void)?

    /// Takes ownership of `descriptor`. `close()` is the only thing that closes
    /// it, and it must be called.
    public init(descriptor: Int32) {
        self.descriptor = descriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
    }

    public func start() {
        queue.async { [self] in
            guard liveSourceCount == 0, !isClosed else { return }

            // Strongly captured, both handlers, both sources. A started pump
            // owns a descriptor and two dispatch sources, one of them
            // deliberately suspended — and releasing a suspended source traps
            // the process. Held by its own sources it cannot reach `deinit`
            // until `close` has cancelled them, so the worst an owner who
            // forgets to close can do is leak a descriptor. The daemon kills
            // the process either way when the peer goes.
            let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            reader.setEventHandler { self.drain() }
            reader.setCancelHandler { self.sourceFinished() }
            readSource = reader
            liveSourceCount += 1

            // Made once and kept, suspended, for the life of the pump. A source
            // per congested write would have to be cancelled and remade, and
            // every one of those is another cancel handler racing whoever
            // closes the descriptor.
            let writer = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
            writer.setEventHandler { self.flush() }
            writer.setCancelHandler { self.sourceFinished() }
            // Activated *then* suspended, in that order. A source that was
            // never activated is inactive rather than merely suspended: its
            // cancel handler never runs — so the descriptor would never be
            // closed — and releasing it traps. This runs on the source's own
            // queue, so its handler cannot slip in between the two calls.
            writer.activate()
            writer.suspend()
            writeSource = writer
            liveSourceCount += 1

            reader.activate()
        }
    }

    /// Bytes the user typed or pasted, delivered in order at the pace the
    /// program reads them.
    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard !hasEnded, !isClosed else { return }
            guard pending.count - pendingOffset + data.count <= Self.pendingInputLimit else { return }
            pending.append(data)
            flush()
        }
    }

    /// Tell the program its window changed.
    ///
    /// This is what delivers `SIGWINCH`: the kernel sends it to the terminal's
    /// foreground process group whenever the size on the master changes, so a
    /// full-screen program redraws itself with nothing else involved. There is
    /// no round trip to the daemon for it — the app holds the master.
    public func resize(columns: UInt16, rows: UInt16) {
        queue.async { [self] in
            guard !isClosed else { return }
            var size = winsize(
                ws_row: max(1, rows),
                ws_col: max(1, columns),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            _ = ioctl(descriptor, TIOCSWINSZ, &size)
        }
    }

    /// Hang up.
    ///
    /// Closing the master revokes the terminal, and the kernel sends `SIGHUP`
    /// to the session — which ends a shell. A program that ignores `SIGHUP`
    /// survives it, so whoever owns this pump also asks the daemon to kill the
    /// process; the two together are what stops a root shell outliving the
    /// screen that opened it.
    public func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            finish()
            guard liveSourceCount > 0 else {
                // Never started: nothing but this holds the descriptor.
                isClosed = true
                Darwin.close(descriptor)
                return
            }
            // A suspended source never runs its cancel handler, and the
            // descriptor would then never be closed.
            if !isWriteSourceRunning {
                isWriteSourceRunning = true
                writeSource?.resume()
            }
            writeSource?.cancel()
            readSource?.cancel()
            writeSource = nil
            readSource = nil
        }
    }

    // MARK: - Pumping

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: Self.readByteCount)
        while true {
            let got = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, Self.readByteCount) }
            if got > 0 {
                onOutput?(Data(buffer[0 ..< got]))
                // A short read means the kernel has no more for now; asking
                // again only to be told `EAGAIN` costs a syscall per wake.
                if got < Self.readByteCount { return }
                continue
            }
            if got < 0, errno == EINTR { continue }
            if got < 0, errno == EAGAIN { return }
            // Zero is EOF, and `EIO` is what a master reads once the slave's
            // last holder is gone. Both mean the program let go of the
            // terminal, and a read source at EOF fires forever — so stop
            // reading, but leave the descriptor for `close` to release.
            readSource?.cancel()
            readSource = nil
            finish()
            return
        }
    }

    private func flush() {
        while pendingOffset < pending.count {
            let wrote = pending.withUnsafeBytes { buffer -> Int in
                write(descriptor, buffer.baseAddress! + pendingOffset, buffer.count - pendingOffset)
            }
            if wrote > 0 {
                pendingOffset += wrote
                continue
            }
            if wrote < 0, errno == EINTR { continue }
            if wrote < 0, errno == EAGAIN {
                if !isWriteSourceRunning {
                    isWriteSourceRunning = true
                    writeSource?.resume()
                }
                return
            }
            // The terminal is gone, and so is anything still queued for it.
            break
        }
        pending.removeAll(keepingCapacity: false)
        pendingOffset = 0
        if isWriteSourceRunning {
            isWriteSourceRunning = false
            writeSource?.suspend()
        }
    }

    /// The program is gone. Reported once; the descriptor stays open until
    /// `close`, because the caller may still be draining what it left behind.
    private func finish() {
        guard !hasEnded else { return }
        hasEnded = true
        let handler = onEnd
        onEnd = nil
        handler?()
    }

    private func sourceFinished() {
        liveSourceCount -= 1
        guard liveSourceCount == 0, !isClosed else { return }
        isClosed = true
        Darwin.close(descriptor)
    }

    deinit {
        // Only ever reached with no live sources: a started pump is retained by
        // them until `close` cancels them. What is left is a pump that was
        // never started, or one whose sources are gone and whose descriptor
        // they already closed.
        if liveSourceCount == 0, !isClosed { Darwin.close(descriptor) }
    }
}
