import Darwin
import Dispatch
import FilaFileOps
import FilaLog
import FilaProtocol
import Foundation
import XPC

/// The Mach service listener, and the dispatcher over `FilaFileOps`.
///
/// `filad` is an on-demand LaunchDaemon: launchd starts it when the app looks
/// the service up and it exits once the last client is gone, so an idle device
/// carries no process for it. That also keeps it clear of launchd's 6 MB jetsam
/// budget — but the reason it stays clear of it under load is architectural,
/// not incidental: file bytes never enter this process. See `FilaOperation`.
///
/// There is no file logic here on purpose. Every case below decodes a request,
/// calls one function in `FilaFileOps`, and encodes the reply; the decisions
/// that can destroy the user's filesystem live in a module that `swift test`
/// can reach without a daemon.
// Dispatch owns isolation here because XPC delivers events on a serial queue.
// All mutable state, including startup, belongs to controlQueue. Background
// work captures immutable jobs/connections and returns to that queue before
// accessing server state; entry points assert that boundary at runtime.
final class DaemonServer: @unchecked Sendable {
    private static let idleExitDelay: DispatchTimeInterval = .seconds(3)

    /// One connection's state. Listings and jobs belong to the peer that asked
    /// for them: when it goes away, its directory handles close and its jobs
    /// stop.
    private final class Peer {
        let connection: xpc_connection_t
        /// How `peers` is keyed, carried here so a job's completion can find
        /// its way back without every call passing the pair around.
        let key: ObjectIdentifier
        let listings = ListingRegistry()
        var jobs: [UInt64: FileJob] = [:]
        /// The terminals this peer opened. A pid and a dispatch source each —
        /// the master descriptor and every byte of the stream belong to the
        /// app. Departure hangs up their original process groups and waits for
        /// the direct children to be reaped. Other job-control groups and
        /// detached sessions are outside this ownership boundary.
        var terminals: [UInt64: TerminalProcess] = [:]
        let terminalOwner = UUID().uuidString

        init(connection: xpc_connection_t, key: ObjectIdentifier) {
            self.connection = connection
            self.key = key
        }
    }

    private let controlQueue = DispatchQueue(
        label: "wiki.qaq.fila.daemon.control",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    /// Jobs run off the control queue, so a copy that takes minutes does not
    /// stall the next request — but one at a time. A concurrent queue grows a
    /// worker thread for every block that blocks, and every job blocks inside
    /// `copyfile`/`removefile` for its whole life; a client that started sixty
    /// would pin sixty threads in a process launchd sizes at 6 MB. They are all
    /// waiting on the same flash device anyway.
    private let jobQueue = DispatchQueue(label: "wiki.qaq.fila.daemon.jobs", qos: .utility)
    /// Searches run on their own serial queue rather than behind the copies.
    ///
    /// The argument for one lane above is that every job there blocks on the
    /// same flash device, so a second thread buys nothing. A search does not:
    /// `searchResultLimit` caps the matches it reports, not the entries it
    /// walks, so a query that matches little walks the whole device for
    /// minutes. Sharing the lane would mean a paste sitting at 0% until the
    /// search the user forgot about finished. Still serial, and for the
    /// original reason — a concurrent queue grows a thread per blocked walk
    /// inside a process launchd sizes at 6 MB — so a second search waits for
    /// the first, which is why the app cancels one before starting the next.
    private let searchQueue = DispatchQueue(label: "wiki.qaq.fila.daemon.search", qos: .userInitiated)
    /// Archive jobs on a lane of their own, for the search's reason: this
    /// process only waits on the helper's pipe, and a ten-minute compression
    /// must not hold a delete at 0%.
    private let archiveQueue = DispatchQueue(label: "wiki.qaq.fila.daemon.archive", qos: .utility)
    private let authenticator = PeerAuthenticator()
    /// No `writableRoot`: a root file manager writes where root can. The
    /// helper sits beside this binary, under the same install root.
    private let operations = FileOperations(
        bootstrapRoot: InstallRoot.current,
        archiveHelper: InstallRoot.current + "/usr/libexec/fila-archive"
    )

    private var listener: xpc_connection_t?
    private var terminationSources: [DispatchSourceSignal] = []
    private var peers = [ObjectIdentifier: Peer]()
    private var idleGeneration: UInt64 = 0
    private var nextJobIdentifier: UInt64 = 1
    private var nextTerminalIdentifier: UInt64 = 1
    private var runningJobCount = 0
    /// Spawned processes that have not been reaped, across every peer. Counted
    /// for the same reason `runningJobCount` is: exiting underneath one leaves
    /// something running as root that nothing is watching any more.
    private var liveTerminalCount = 0

    func start() throws {
        try controlQueue.sync { try startOnControlQueue() }
    }

    private func startOnControlQueue() throws {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard listener == nil else { return }
        guard let listener = FilaProtocol.serviceName.withCString({
            filaCreateMachServiceConnection($0, controlQueue, FilaXPCFlag.listener)
        }) else {
            throw DaemonError.listenerUnavailable
        }
        self.listener = listener

        for number in [SIGTERM, SIGINT] {
            // A caught handler resets to SIG_DFL at exec. SIG_IGN would leak
            // into terminal children and make them ignore these signals too.
            signal(number, { _ in })
            let source = DispatchSource.makeSignalSource(signal: number, queue: controlQueue)
            source.setEventHandler { [weak self] in self?.stop() }
            source.activate()
            terminationSources.append(source)
        }

        xpc_connection_set_event_handler(listener) { [weak self] event in
            autoreleasepool { self?.accept(event) }
        }
        xpc_connection_activate(listener)

        // launchd starts us on a service lookup, and a lookup is not a
        // connection: something that resolves the name and then thinks better
        // of it would otherwise leave a resident daemon on an idle device.
        scheduleIdleExit()
    }

    private func accept(_ event: xpc_object_t) {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard xpc_get_type(event) == FilaXPC.typeConnection else { return }
        guard listener != nil else {
            xpc_connection_cancel(event)
            return
        }
        guard let peerProcessIdentifier = authenticator.authenticate(event) else {
            // A refusal here is a security event rather than a mistake, so it
            // is logged at a level that is never switched off.
            FilaLog.warning("peer rejected")
            xpc_connection_cancel(event)
            scheduleIdleExit()
            return
        }
        FilaLog.info("peer accepted pid \(peerProcessIdentifier)")

        cancelIdleExit()
        let key = ObjectIdentifier(event as AnyObject)
        peers[key] = Peer(connection: event, key: key)
        xpc_connection_set_target_queue(event, controlQueue)
        xpc_connection_set_event_handler(event) { [weak self] message in
            autoreleasepool { self?.handle(message, key: key) }
        }
        xpc_connection_activate(event)
    }

    private func handle(_ message: xpc_object_t, key: ObjectIdentifier) {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard let peer = peers[key] else { return }
        guard xpc_get_type(message) == FilaXPC.typeDictionary else {
            // The connection errors and friends arrive here.
            peerInvalidated(key)
            return
        }
        guard let reply = xpc_dictionary_create_reply(message) else { return }

        let operation = FilaOperation(rawValue: xpc_dictionary_get_uint64(message, FilaWireKey.operation))
        do {
            guard let operation else { throw FilaFailure(code: .invalidRequest) }
            try perform(operation, message: message, into: reply, peer: peer)
            xpc_dictionary_set_int64(reply, FilaWireKey.code, FilaReplyCode.success.rawValue)
            // Every request that succeeded, at verbose. `fetchLog` is the one
            // exception, and has to be: the viewer polls once a second and a
            // ring recording its own poll would eventually hold nothing else.
            if operation != .fetchLog {
                FilaLog.verbose("\(operation.name) \(FilaLog.requestPath(message)) ok")
            }
        } catch let failure as FilaFailure {
            failure.encode(into: reply)
            // The half with the diagnostic value. Where the guard refused, this
            // is the only record of it — the app is told `protectedPath` and
            // nothing about which ancestor matched.
            FilaLog.log(
                Self.level(for: failure.code),
                Self.describe(operation?.name ?? "?", path: FilaLog.requestPath(message), failure: failure)
            )
        } catch {
            xpc_dictionary_set_int64(reply, FilaWireKey.code, FilaReplyCode.operationFailed.rawValue)
            FilaLog.error("\(operation?.name ?? "?") \(FilaLog.requestPath(message)) failed")
        }
        xpc_connection_send_message(peer.connection, reply)

        // Answered first, then dropped: a client that says goodbye still wants
        // to know the daemon heard it.
        if operation == .goodbye {
            xpc_connection_cancel(peer.connection)
            peerInvalidated(key)
        }
    }

    // MARK: - Log

    /// A refusal is not automatically trouble. `notFound` is what a `stat` of a
    /// path the user just deleted answers, and `cancelled` is the user's own
    /// doing; logging either as an error would bury the ones that matter.
    private static func level(for code: FilaReplyCode) -> FilaLog.Level {
        switch code {
        case .notFound, .cancelled: return .verbose
        case .protectedPath, .notPermitted, .invalidRequest, .wrongPassword: return .warning
        default: return .error
        }
    }

    /// `subject` is what was being done — an operation's name, or a job's id.
    private static func describe(_ subject: String, path: String, failure: FilaFailure) -> String {
        var line = "\(subject) \(path) \(failure.code.name)"
        // The number is the answer to "it wouldn't delete": as root, EPERM is
        // almost always an immutable flag and nothing but the errno says so.
        if failure.systemError != 0 {
            line += " errno \(failure.systemError) \(failure.systemErrorDescription ?? "")"
        }
        return line
    }

    // MARK: - Operations

    private func perform(
        _ operation: FilaOperation,
        message: xpc_object_t,
        into reply: xpc_object_t,
        peer: Peer
    ) throws {
        switch operation {
        case .hello:
            xpc_dictionary_set_uint64(reply, FilaWireKey.version, FilaProtocol.version)
            xpc_dictionary_set_string(reply, FilaWireKey.installRoot, InstallRoot.current)

        case .listDirectory:
            let page = try peer.listings.page(
                directory: try string(FilaWireKey.path, in: message),
                cursor: xpc_dictionary_get_uint64(message, FilaWireKey.cursor)
            )
            let entries = xpc_array_create(nil, 0)
            for node in page.entries {
                xpc_array_set_value(entries, FilaXPC.arrayAppend, node.encoded())
            }
            xpc_dictionary_set_value(reply, FilaWireKey.entries, entries)
            xpc_dictionary_set_uint64(reply, FilaWireKey.cursor, page.cursor)

        case .statPath:
            let details = try operations.details(of: try string(FilaWireKey.path, in: message))
            xpc_dictionary_set_value(reply, FilaWireKey.details, details.encoded())

        case .openPath:
            let descriptor = try operations.open(
                try string(FilaWireKey.path, in: message),
                flags: Int32(truncatingIfNeeded: xpc_dictionary_get_int64(message, FilaWireKey.openFlags)),
                mode: mode_t(truncatingIfNeeded: xpc_dictionary_get_uint64(message, FilaWireKey.mode))
            )
            // `xpc_dictionary_set_fd` duplicates it, so this process keeps none
            // of them: a browsing session that leaked one per preview would run
            // the daemon out of descriptors.
            defer { close(descriptor) }
            xpc_dictionary_set_fd(reply, FilaWireKey.descriptor, descriptor)

        case .createNode:
            guard let template = NodeTemplate(decoding: message) else {
                throw FilaFailure(code: .invalidRequest)
            }
            try operations.create(
                template,
                at: try string(FilaWireKey.path, in: message),
                mode: optionalMode(FilaWireKey.mode, in: message)
            )

        case .rename:
            try operations.rename(
                try string(FilaWireKey.path, in: message),
                to: try string(FilaWireKey.destination, in: message),
                exclusive: xpc_dictionary_get_bool(message, FilaWireKey.exclusive),
                overrideGuard: xpc_dictionary_get_bool(message, FilaWireKey.overrideGuard)
            )

        case .setAttributes:
            guard let value = xpc_dictionary_get_value(message, FilaWireKey.attributes),
                  let change = AttributeChange(decoding: value) else {
                throw FilaFailure(code: .invalidRequest)
            }
            // ponytail: a recursive change runs to completion on the control
            // queue, so a chown of a very large tree holds up the next request.
            // It has no progress and no cancellation for the same reason.
            // Making it a job is the upgrade, and it needs wire vocabulary
            // `FilaJobKind` does not have yet.
            try operations.setAttributes(change, at: try string(FilaWireKey.path, in: message))

        case .replaceItem:
            try operations.replaceItem(
                at: try string(FilaWireKey.destination, in: message),
                withTemporary: try string(FilaWireKey.path, in: message)
            )

        case .mountPoints:
            let mounts = xpc_array_create(nil, 0)
            for mount in try operations.mountPoints() { xpc_array_append_value(mounts, mount.encoded()) }
            xpc_dictionary_set_value(reply, FilaWireKey.mounts, mounts)

        case .volumeInfo:
            let volume = try operations.volumeInfo(for: try string(FilaWireKey.path, in: message))
            xpc_dictionary_set_value(reply, FilaWireKey.volume, volume.encoded())

        case .readExtendedAttribute:
            let value = try operations.extendedAttribute(
                try string(FilaWireKey.attributeName, in: message),
                at: try string(FilaWireKey.path, in: message)
            )
            value.withUnsafeBytes {
                xpc_dictionary_set_data(reply, FilaWireKey.attributeValue, $0.baseAddress, $0.count)
            }

        case .startJob:
            guard let request = JobRequest(decoding: message) else {
                throw FilaFailure(code: .invalidRequest)
            }
            xpc_dictionary_set_uint64(reply, FilaWireKey.jobIdentifier, startJob(request, peer: peer))

        case .cancelJob:
            peer.jobs[xpc_dictionary_get_uint64(message, FilaWireKey.jobIdentifier)]?.cancel()

        case .fetchLog:
            // The level travels with the poll rather than in an operation of
            // its own, so turning Verbose on in the app is one round trip and
            // takes effect on the next line the daemon writes.
            let request = FilaLog.Record.decodeRequest(message)
            if let level = request.level, level != FilaLog.minimumLevel {
                FilaLog.minimumLevel = level
                FilaLog.info("log level is now \(level.tag)")
            }
            let snapshot = FilaLog.snapshot(since: request.sequence)
            FilaLog.Record.encodeReply(snapshot.records, dropped: snapshot.dropped, into: reply)

        case .openTerminal:
            try openTerminal(message, into: reply, peer: peer)

        case .closeTerminal:
            // Signalled, not forgotten. The entry goes when the process is
            // actually reaped, so `terminalSessionsPerPeer` counts live
            // processes rather than open screens — a client that closed eight
            // terminals and immediately opened eight more would otherwise have
            // sixteen shells running as root.
            let owner = xpc_dictionary_get_string(message, FilaWireKey.terminalOwner).map { String(cString: $0) }
            if let owner, owner != peer.terminalOwner { throw FilaFailure(code: .invalidRequest) }
            let process = peer.terminals[xpc_dictionary_get_uint64(message, FilaWireKey.terminalIdentifier)]
            process?.terminate()
            // Only the watch callback removes this entry, after group
            // signalling and direct-child reaping have completed.
            xpc_dictionary_set_bool(reply, FilaWireKey.terminalExited, owner != nil && process == nil)

        case .goodbye:
            // Nothing to do but say yes. `handle` drops the peer once the
            // answer is on its way.
            break

        case .jobEvent, .searchResult:
            // Only ever travel the other way.
            throw FilaFailure(code: .invalidRequest)
        }
    }

    /// Open a pseudo-terminal, run one program on it, and hand the master
    /// descriptor back.
    ///
    /// The request carries a path or a package, one of two users, a directory
    /// and a window size, and that is the whole of the client's say:
    /// `FileOperations.openTerminal` composes argv and the environment itself,
    /// and refuses anything that is not a real executable regular file. A
    /// package runs the bootstrap's `dpkg -i` on it, as root, with that fixed
    /// argv. There is no operation on this daemon that takes a command line,
    /// and there is not going to be one.
    ///
    /// The user is decoded as a `TerminalUser` and an unrecognised value is
    /// refused outright rather than clamped or defaulted. That guard is the
    /// whole difference between "which of the two users" and "which uid": the
    /// field is two integers wide by construction, so no client — this app,
    /// a future one, or something that got past `PeerAuthenticator` — can name
    /// an account the daemon did not offer.
    private func openTerminal(_ message: xpc_object_t, into reply: xpc_object_t, peer: Peer) throws {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard peer.terminals.count < FilaProtocol.terminalSessionsPerPeer else {
            throw FilaFailure(code: .notPermitted, systemError: EMFILE)
        }
        // An absent key reads as 0, which is `.root` — what every terminal was
        // before there was a choice.
        guard let user = TerminalUser(rawValue: xpc_dictionary_get_int64(message, FilaWireKey.terminalUser))
        else {
            throw FilaFailure(code: .invalidRequest)
        }
        // ponytail: the spawn blocks this control queue until the child reaches
        // its program spawn — it waits on the pipe the session holder reports failure
        // through, which is what turns "the terminal opened and closed again"
        // into a readable errno. On a device that wait is AMFI validating a
        // signature: tens of milliseconds, once per terminal the user opens,
        // during which a listing waits. Moving it to a queue of its own is the
        // upgrade, and it needs `handle` to be able to answer a request later
        // than it read it, which nothing here can do yet.
        let package = xpc_dictionary_get_string(message, FilaWireKey.package).map { String(cString: $0) }
        let launch = try operations.openTerminal(TerminalRequest(
            executable: xpc_dictionary_get_string(message, FilaWireKey.path).map { String(cString: $0) },
            package: package,
            user: user,
            // Absent reads as false: a client that does not know about the
            // setting gets what every terminal got before it existed.
            redirectsScriptInterpreter: xpc_dictionary_get_bool(message, FilaWireKey.redirectsScriptInterpreter),
            workingDirectory: xpc_dictionary_get_string(message, FilaWireKey.workingDirectory)
                .map { String(cString: $0) },
            columns: UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(message, FilaWireKey.columns)),
            rows: UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(message, FilaWireKey.rows))
        ))
        // The same trade `openPath` makes: XPC duplicates the descriptor into
        // the message, so this process keeps none of it and never sees a byte
        // of the stream.
        defer { close(launch.descriptor) }

        let identifier = nextTerminalIdentifier
        nextTerminalIdentifier &+= 1
        peer.terminals[identifier] = launch.process
        liveTerminalCount += 1
        let key = peer.key
        launch.process.watch { [weak self] in
            self?.controlQueue.async {
                guard let self else { return }
                self.peers[key]?.terminals[identifier] = nil
                self.liveTerminalCount -= 1
                // Group signalling and direct-child reaping are complete.
                // This count does not track detached or job-control groups.
                self.scheduleIdleExit()
            }
        }

        // The one place a root daemon starts a process, so it leaves a line
        // saying what it started and as whom — the uid it resolved, not the one
        // that was asked for — and, for the one argv that carries a file the
        // client chose, which file.
        FilaLog.info("terminal \(identifier) \(launch.executable)\(package.map { " -i \($0)" } ?? "") via \(launch.launcher) uid \(launch.userIdentifier)")
        xpc_dictionary_set_fd(reply, FilaWireKey.descriptor, launch.descriptor)
        xpc_dictionary_set_uint64(reply, FilaWireKey.terminalIdentifier, identifier)
        xpc_dictionary_set_string(reply, FilaWireKey.terminalOwner, peer.terminalOwner)
        xpc_dictionary_set_string(reply, FilaWireKey.path, launch.executable)
        xpc_dictionary_set_uint64(reply, FilaWireKey.userIdentifier, UInt64(launch.userIdentifier))
    }

    private func startJob(_ request: JobRequest, peer: Peer) -> UInt64 {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        let identifier = nextJobIdentifier
        nextJobIdentifier &+= 1

        let job = FileJob(request: request, operations: operations)
        peer.jobs[identifier] = job
        runningJobCount += 1
        FilaLog.info(
            "job \(identifier) \(request.kind) \(request.sources.count) source(s)"
                + " → \(request.destination ?? "-")"
                + (request.useTrash ? " trash" : "")
                + (request.overrideGuard ? " override" : "")
        )

        // Events are unsolicited messages on the peer's own connection, not
        // replies: the job outlives the request that started it, and the screen
        // that started it may be gone by the time it ends.
        let connection = peer.connection
        let key = peer.key
        let queue = request.kind == .search ? searchQueue : request.kind.isArchive ? archiveQueue : jobQueue
        queue.async { [weak self] in
            let outcome = job.run { progress in
                xpc_connection_send_message(connection, JobEvent.progress(progress).encoded(jobIdentifier: identifier))
            } matches: { batch in
                // A search's answers, on their own message: `jobEvent` says how
                // far along the job is, this says what it found. Both are
                // unsolicited and both are capped — a batch is at most
                // `FilaProtocol.searchBatchMatchCount` matches.
                xpc_connection_send_message(connection, batch.encoded(jobIdentifier: identifier))
            } note: { line in
                // What the helper left out and why. The only record of it.
                FilaLog.warning("job \(identifier) \(line)")
            }
            // A job's outcome is where a copy that lost a file shows up, and it
            // is not carried by any reply — the request that started it was
            // answered minutes ago.
            FilaLog.log(
                outcome.code == .success ? .info : Self.level(for: outcome.code),
                Self.describe("job \(identifier)", path: outcome.path ?? "-", failure: outcome)
            )
            xpc_connection_send_message(connection, JobEvent.completed(outcome).encoded(jobIdentifier: identifier))
            self?.controlQueue.async { self?.jobFinished(identifier, key: key) }
        }
        return identifier
    }

    private func jobFinished(_ identifier: UInt64, key: ObjectIdentifier) {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        peers[key]?.jobs[identifier] = nil
        runningJobCount -= 1
        scheduleIdleExit()
    }

    // MARK: - Lifetime

    private func stop() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard let listener else { return }
        self.listener = nil
        xpc_connection_cancel(listener)
        FilaLog.info("filad stopping; cancelling owned work")
        for key in Array(peers.keys) {
            if let peer = peers[key] { xpc_connection_cancel(peer.connection) }
            peerInvalidated(key)
        }
        // Completion callbacks keep the existing idle gate closed until jobs
        // have stopped and direct terminal children have been reaped.
        scheduleIdleExit()
    }

    private func peerInvalidated(_ key: ObjectIdentifier) {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard let peer = peers.removeValue(forKey: key) else { return }
        FilaLog.info("peer gone, \(peer.jobs.count) job(s) cancelled")
        peer.listings.closeAll()
        // A peer that has gone cannot read progress and cannot be asked what to
        // do about a collision, so its jobs stop rather than run on as root
        // with nobody watching.
        for job in peer.jobs.values { job.cancel() }
        // Tty hangup alone can be ignored. Also force the original process
        // groups to stop, then reap the direct children. TerminalProcess does
        // not claim ownership of other job-control groups or detached sessions.
        for terminal in peer.terminals.values { terminal.terminate() }
        scheduleIdleExit()
    }

    /// Nothing is idle any more. Invalidates whatever timer is pending without
    /// arming another.
    private func cancelIdleExit() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        idleGeneration &+= 1
    }

    /// The timer body is the only thing that decides whether to exit, so every
    /// caller may arm it unconditionally.
    private func scheduleIdleExit() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        idleGeneration &+= 1
        let scheduledGeneration = idleGeneration
        // An explicit stop needs no reconnect grace after cleanup finishes.
        let delay: DispatchTimeInterval = listener == nil ? .seconds(0) : Self.idleExitDelay
        controlQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.idleGeneration == scheduledGeneration, self.peers.isEmpty else { return }
            // A job survives the peer that started it long enough to finish or
            // to notice it was cancelled. Exiting underneath one would leave a
            // half-copied tree with nobody to report it.
            guard self.runningJobCount == 0 else { return }
            // Group signalling must finish and each direct child must be
            // reaped before this owner exits. This is not a descendant count.
            guard self.liveTerminalCount == 0 else { return }

            exit(EXIT_SUCCESS)
        }
    }

    // MARK: - Decoding

    private func string(_ key: String, in message: xpc_object_t) throws -> String {
        guard let value = xpc_dictionary_get_string(message, key) else {
            throw FilaFailure(code: .invalidRequest)
        }
        return String(cString: value)
    }

    /// Absent means "the default for this kind", which is not the same as zero.
    private func optionalMode(_ key: String, in message: xpc_object_t) -> mode_t? {
        guard xpc_dictionary_get_value(message, key) != nil else { return nil }
        return mode_t(truncatingIfNeeded: xpc_dictionary_get_uint64(message, key))
    }
}

enum DaemonError: Error {
    case listenerUnavailable
}
