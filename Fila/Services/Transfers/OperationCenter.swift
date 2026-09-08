import FilaClient
import FilaProtocol
import Foundation

extension Notification.Name {
    /// Something the sidebar renders changed: favorites, recents, tabs, or the
    /// operation list. One notification for all of them because the sidebar
    /// rebuilds its whole snapshot anyway.
    static let filaSidebarChanged = Notification.Name("wiki.qaq.fila.sidebar")

    /// An operation finished. The notification's object is the `[String]` of
    /// directories it touched; a browser showing one of them reloads.
    ///
    /// The name says "job" for the browsers that already listen to it. It now
    /// fires for renames and creations too, which is why they no longer need to
    /// reload by hand.
    static let filaJobFinished = Notification.Name("wiki.qaq.fila.job.finished")
}

/// Every filesystem change the user asked for, in one list.
///
/// Three shapes go in and one comes out. A **daemon job** — copy, move, delete,
/// trash — reports over `DaemonLink.jobEvents` and stops over XPC. A **single
/// round trip** — rename, create, setAttributes, replaceItem — has no progress
/// and is over before a bar could be read. **Work the app runs itself** —
/// compressing to a zip, extracting one — reports from its own callback and
/// stops by dropping its task. Nothing above this class is allowed to care
/// which of the three it was looking at.
///
/// `announce(_:)` owns ordinary operation feedback. A caller that needs its own
/// recovery choices awaits a silent operation and presents that result once.
@MainActor
final class OperationCenter: ObservableObject {
    /// What the user asked for. The kind is the only discriminator the surfaces
    /// need — it carries the verb, the icon, and whether the work is over too
    /// fast for a progress row to mean anything.
    enum Kind: String {
        case copy, move, trash, delete, compress, extract, rename, create, attributes, download

        /// Over before a progress row could be read, so its success is invisible
        /// unless something says so. This is the whole difference between a
        /// toast and a transfers entry.
        var isInstant: Bool {
            switch self {
            case .rename, .create, .attributes: return true
            default: return false
            }
        }
    }

    /// Which outcomes this center announces. A caller that presents its own
    /// failure recovery can keep success feedback without a second error toast.
    enum Feedback {
        case automatic, silent, successOnly
    }

    /// Where an operation is in its life. Three states, not five: `.finished`
    /// carries the daemon's own verdict — `.success`, `.cancelled`, or the
    /// failure — because that is exactly what arrives on the wire, and
    /// splitting it into three cases here only means translating it back at
    /// every use.
    enum State {
        case running(JobProgress?)
        case finished(FilaFailure)
        /// The app was killed while this was running. Nothing came back to say
        /// how it ended, because nothing was left to say it. See `breadcrumb`.
        case interrupted
    }

    /// What is still holding the work, and therefore how it stops. Nil once
    /// nothing is: a finished operation, or one seeded from a breadcrumb.
    enum Control {
        case job(UInt64)
        case task(Task<Void, Never>)
    }

    /// The inverse of an operation, where one genuinely exists.
    ///
    /// Renaming reverses with a rename; trashing restores the recorded item,
    /// using a copy and removal when its origin is on another volume.
    /// The inverse of a copy, a creation or an extraction is a *delete*,
    /// and destroying the user's files to undo is worse than not undoing.
    struct Undo {
        let title: String
        let perform: () async throws -> Void
    }

    struct Operation: Identifiable {
        var id = UUID()
        let kind: Kind
        /// What the row says it is doing: "Copying".
        let title: String
        /// What it is doing it to: "3 items → /var/mobile".
        let subtitle: String
        var state: State
        /// Directories a finished operation should make reload.
        let affected: [String]
        var control: Control?
        /// Set when the operation starts, kept only if it actually succeeded —
        /// there is nothing to put back after a failure or a cancellation.
        var undo: Undo?
        var feedback: Feedback = .automatic
        /// Called once, with the daemon's own verdict, when the operation ends.
        ///
        /// Resumes `awaitJob` callers only after the row holds the final result.
        var whenFinished: ((FilaFailure) -> Void)?

        var isRunning: Bool {
            if case .running = state { return true }
            return false
        }

        var progress: JobProgress? {
            if case let .running(progress) = state { return progress }
            return nil
        }

        var succeeded: Bool {
            if case let .finished(failure) = state { return failure.code == .success }
            return false
        }

        /// The failure worth showing — never `.success`, and never `.cancelled`,
        /// which the user asked for and does not need told about.
        var failure: FilaFailure? {
            guard case let .finished(failure) = state,
                  failure.code != .success, failure.code != .cancelled else { return nil }
            return failure
        }

        var isCancellable: Bool { isRunning && control != nil && !kind.isInstant }
    }

    /// Running first, then what recently finished, newest first.
    @Published private(set) var operations: [Operation] = []

    private unowned let session: FileSession

    /// Completions that arrived before their row existed. See `startJob`.
    private var earlyCompletions: [UInt64: FilaFailure] = [:]

    /// How many finished rows the list keeps. It is a receipt, not a history.
    private static let finishedLimit = 20
    private static let breadcrumbKey = "wiki.qaq.fila.operations.inflight"

    init(session: FileSession) {
        self.session = session
        seedInterrupted()
        Task { [weak self] in
            for await update in session.link.jobEvents { self?.apply(update) }
        }
        session.link.onLinkLost = { [weak self] in
            Task { @MainActor in self?.abandonDaemonJobs() }
        }
    }

    /// Ends every running daemon job, because they have already ended.
    ///
    /// `filad` runs a job for the connection that asked for it and cancels
    /// every one of a peer's jobs when the peer goes away. So a link that
    /// dropped took the work with it, and no `.completed` is ever coming for
    /// those rows — left alone they sit at 40% for the life of the app, and
    /// anything awaiting one through `runJob` waits with them.
    ///
    /// Ids are collected first because `finish` moves rows around underneath
    /// the iteration.
    private func abandonDaemonJobs() {
        let lost = operations.filter { operation in
            guard operation.isRunning, case .job = operation.control else { return false }
            return true
        }.map(\.id)
        for identity in lost {
            finish(identity, FilaFailure(code: .operationFailed, systemError: ECONNRESET))
        }
    }

    // MARK: - Daemon jobs

    func copy(_ paths: [String], to destination: String, overwrite: Bool = false) {
        let request = JobRequest(kind: .copy, sources: paths, destination: destination, overwrite: overwrite)
        // No undo: the inverse of a copy is a delete, and a "undo" that removes
        // files is not one.
        begin(request, kind: .copy, subtitle: Self.describe(paths, destination: destination))
    }

    func move(_ paths: [String], to destination: String, overwrite: Bool = false) {
        let request = JobRequest(kind: .move, sources: paths, destination: destination, overwrite: overwrite)
        // A safe inverse needs an identity that survives the move. Ordinary
        // moves carry no recovery record, so undoing by name could move a
        // different file that subsequently occupied the destination.
        begin(request, kind: .move, subtitle: Self.describe(paths, destination: destination))
    }

    /// Capture the identities before starting the delete so success can offer
    /// Put Back. Failures and cancellations discard this offer with the row.
    func trash(_ paths: [String], feedback: Feedback = .automatic) async throws -> FilaFailure {
        let identity = UUID()
        var recorded: [String] = []
        for path in paths {
            guard let details = try? await session.perform(retryOnDisconnect: true, {
                try await $0.details(of: path)
            }) else { continue }
            // Same-volume hard links cannot carry an independent origin note.
            guard details.node.kind == .directory || details.node.linkCount == 1 else { continue }
            recorded.append(details.path)
        }
        let undo = recorded.isEmpty || recorded.count != paths.count ? nil : Undo(title: String(localized: "Put Back")) { [weak self] in
            try await self?.putBack(recorded, identity: identity)
        }
        return try await awaitJob(
            JobRequest(kind: .delete, sources: paths, useTrash: true, trashID: identity),
            kind: .trash, subtitle: Self.describe(paths), undo: undo, feedback: feedback
        )
    }

    /// `removefile(3)`. There is nothing left to put back, so there is no undo.
    func deletePermanently(_ paths: [String]) {
        begin(JobRequest(kind: .delete, sources: paths), kind: .delete, subtitle: Self.describe(paths))
    }

    /// Starts a job and adds its row. Throws only if the daemon refused to
    /// *start* it; everything after that arrives on `jobEvents`.
    ///
    /// Callers that present progress use the returned job identifier to find
    /// the operation they started.
    @discardableResult
    func startJob(
        _ request: JobRequest,
        kind: Kind,
        title: String,
        subtitle: String,
        undo: Undo? = nil,
        feedback: Feedback = .automatic,
        whenFinished: ((FilaFailure) -> Void)? = nil
    ) async throws -> UInt64 {
        var directories = request.sources.map { ($0 as NSString).deletingLastPathComponent }
        if let destination = request.destination { directories.append(destination) }
        let identifier = try await session.perform { try await $0.startJob(request) }
        // `filad` counts job identifiers from the start of each run, so one can
        // come back while a row that never heard `.completed` — the daemon was
        // killed, the connection went — is still holding it. That job died with
        // the connection; say so, rather than letting this job's progress land
        // on the wrong row and this job's cancel button stop it.
        if let stale = index(ofJob: identifier) {
            operations[stale].state = .interrupted
            operations[stale].control = nil
            operations[stale].undo = nil
            // Anything awaiting that row is told here, because nothing else
            // ever will be: the connection that would have carried its
            // `.completed` is the one that went away.
            operations[stale].whenFinished?(FilaFailure(code: .operationFailed, systemError: ECONNRESET))
            operations[stale].whenFinished = nil
        }
        let operation = Operation(
            kind: kind,
            title: title,
            subtitle: subtitle,
            state: .running(nil),
            affected: Array(Set(directories)),
            control: .job(identifier),
            undo: undo,
            feedback: feedback,
            whenFinished: whenFinished
        )
        append(operation)
        // A job small enough to finish inside its own `startJob` round trip has
        // already reported itself by now. `jobEvents` is drained by a different
        // task from the one awaiting the reply, so the order is not ours to
        // choose; the completion is held until there is a row to put it on.
        if let early = earlyCompletions.removeValue(forKey: identifier) {
            finish(operation.id, early)
        }
        return identifier
    }

    /// Starts a job, waits for it, and hands back the daemon's own verdict.
    ///
    /// Used when subsequent work or recovery choices depend on the verdict:
    /// Shortcuts, WebDAV responses, clipboard completion and delete failures.
    ///
    /// Feedback stays explicit: `.silent` callers own all presentation;
    /// `.successOnly` callers own errors while retaining completion and Undo.
    ///
    /// A daemon that dies mid-job used to leave this waiting forever, because
    /// nothing synthesized the `.completed` that would never arrive. That is
    /// fixed at the source: `DaemonLink.onLinkLost` turns a dropped connection
    /// into a failure for every job the peer had running, which resumes this
    /// wait and stops the transfers row spinning at the same time.
    func awaitJob(
        _ request: JobRequest,
        kind: Kind,
        subtitle: String,
        undo: Undo? = nil,
        feedback: Feedback = .automatic
    ) async throws -> FilaFailure {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                do {
                    // A job small enough to finish inside `startJob` resumes the
                    // continuation before this call returns, which is exactly
                    // once — the same as every other path out of here.
                    try await startJob(
                        request,
                        kind: kind,
                        title: kind.runningTitle,
                        subtitle: subtitle,
                        undo: undo,
                        feedback: feedback
                    ) { continuation.resume(returning: $0) }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func begin(_ request: JobRequest, kind: Kind, subtitle: String, undo: Undo? = nil) {
        guard !request.sources.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startJob(request, kind: kind, title: kind.runningTitle, subtitle: subtitle, undo: undo)
            } catch let failure as FilaFailure {
                self.record(kind: kind, subtitle: subtitle, failure: failure)
            } catch {
                self.record(kind: kind, subtitle: subtitle, failure: FilaFailure(code: .operationFailed))
            }
        }
    }

    // MARK: - Single round trips

    func rename(_ path: String, to destination: String) {
        let directory = (path as NSString).deletingLastPathComponent
        perform(
            kind: .rename,
            subtitle: Self.describe([path], destination: destination),
            affected: [directory, (destination as NSString).deletingLastPathComponent],
            undo: Undo(title: String(localized: "Undo")) { [weak self] in
                try await self?.session.perform { try await $0.rename(destination, to: path, exclusive: true) }
            }
        ) { try await $0.rename(path, to: destination) }
    }

    func create(_ template: NodeTemplate, at path: String) {
        // No undo: the inverse is a delete, and by the time the offer expires
        // the new file may already hold something.
        perform(
            kind: .create,
            subtitle: (path as NSString).lastPathComponent,
            affected: [(path as NSString).deletingLastPathComponent]
        ) { try await $0.create(template, at: path) }
    }

    /// One request, one reply, no progress. It still gets a row, so that the
    /// failure a toast points at has somewhere to point.
    func perform(
        kind: Kind,
        subtitle: String,
        affected: [String],
        undo: Undo? = nil,
        _ body: @escaping (DaemonLink) async throws -> Void
    ) {
        run(kind: kind, title: kind.runningTitle, subtitle: subtitle, affected: affected, undo: undo) { [session] _ in
            try await session.perform(body)
        }
    }

    // MARK: - Work the app runs itself

    /// Compressing, extracting, downloading: the work is in the app, so the
    /// progress is too. `body` is handed a reporter to say how far it has got —
    /// the same `JobProgress` a daemon job sends, so the row cannot tell the
    /// two apart and neither can anything reading it.
    ///
    /// Cancelling drops the task, which only bites where `body` cooperates —
    /// see the note on `cancel(_:)`.
    func run(
        kind: Kind,
        title: String,
        subtitle: String,
        affected: [String],
        undo: Undo? = nil,
        _ body: @escaping (@escaping (JobProgress) -> Void) async throws -> Void
    ) {
        let operation = Operation(
            kind: kind,
            title: title,
            subtitle: subtitle,
            state: .running(nil),
            affected: affected,
            control: nil,
            undo: undo
        )
        let identity = operation.id
        append(operation)
        // Safe to attach afterwards: the task body cannot run until this
        // actor-isolated function suspends, which it never does.
        let task = Task { [weak self] in
            do {
                try await body { [weak self] progress in self?.report(identity, progress: progress) }
                self?.finish(identity, FilaFailure(code: .success))
            } catch let failure as FilaFailure {
                self?.finish(identity, failure)
            } catch is CancellationError {
                self?.finish(identity, FilaFailure(code: .cancelled))
            } catch {
                self?.finish(identity, FilaFailure(code: .operationFailed))
            }
        }
        if let index = operations.firstIndex(where: { $0.id == identity }) {
            operations[index].control = .task(task)
        }
    }

    // MARK: - Stopping and putting back

    /// Asks an operation to stop.
    ///
    /// A daemon job stops at its next `copyfile`/`removefile` callback. Work
    /// running in the app stops wherever it checks for cancellation, which for
    /// a body that never checks is when it finishes — the button is honest
    /// about asking, not about arriving.
    func cancel(_ operation: Operation) {
        switch operation.control {
        case let .job(identifier):
            Task { [weak self] in
                try? await self?.session.perform { try await $0.cancelJob(identifier) }
            }
        case let .task(task):
            task.cancel()
        case nil:
            break
        }
    }

    /// Runs an operation's inverse as an operation of its own, because a failed
    /// undo has to be as visible as a failed anything else.
    func undo(_ operation: Operation) {
        // Read the offer off the live row, not off the copy the caller is
        // holding: a toast keeps its snapshot for six seconds, and the same
        // undo taken twice puts the file back and then takes it away again.
        guard let index = operations.firstIndex(where: { $0.id == operation.id }),
              let undo = operations[index].undo else { return }
        operations[index].undo = nil
        changed()
        run(
            kind: operation.kind,
            title: undo.title,
            subtitle: operation.subtitle,
            affected: operation.affected
        ) { _ in try await undo.perform() }
    }

    func clearFinished() {
        operations.removeAll { !$0.isRunning }
        changed()
    }

    // MARK: - Events

    private func apply(_ update: DaemonLink.JobUpdate) {
        guard let index = index(ofJob: update.identifier) else {
            // The row is not here yet — see `startJob`. Progress lost in that
            // gap costs nothing; a completion costs the row running forever.
            if case let .completed(failure) = update.event { holdEarly(update.identifier, failure) }
            return
        }
        let identity = operations[index].id
        switch update.event {
        case let .progress(progress):
            report(identity, progress: progress)
        case let .completed(failure):
            finish(identity, failure)
        }
    }

    /// The row a daemon job is running on, for a screen that wants to watch
    /// exactly the operation it just started.
    func operation(forJob identifier: UInt64) -> Operation? {
        index(ofJob: identifier).map { operations[$0] }
    }

    private func index(ofJob identifier: UInt64) -> Int? {
        operations.firstIndex {
            if case let .job(existing)? = $0.control { return existing == identifier }
            return false
        }
    }

    private func holdEarly(_ identifier: UInt64, _ failure: FilaFailure) {
        // Bounded: every identifier here came from a `startJob` about to claim
        // it. The one that never does is a reply lost to a dropped connection,
        // and dropping the oldest is the whole recovery it needs.
        if earlyCompletions.count >= 16 { earlyCompletions.removeAll() }
        earlyCompletions[identifier] = failure
    }

    private func report(_ identity: UUID, progress: JobProgress) {
        guard let index = operations.firstIndex(where: { $0.id == identity }),
              operations[index].isRunning else { return }
        operations[index].state = .running(progress)
        // @Published updates task rows; progress does not change sidebar icons.
    }

    private func finish(_ identity: UUID, _ failure: FilaFailure) {
        guard let index = operations.firstIndex(where: { $0.id == identity }), operations[index].isRunning else { return }
        operations[index].state = .finished(failure)
        operations[index].control = nil
        if failure.code != .success { operations[index].undo = nil }
        var finished = operations[index]
        // Taken off the row that goes back in the list: it fires exactly once,
        // and a spent continuation has no business sitting in the receipts.
        let completion = finished.whenFinished
        finished.whenFinished = nil
        operations.remove(at: index)
        place(finished)
        trimFinished()
        NotificationCenter.default.post(name: .filaJobFinished, object: finished.affected)
        announce(finished)
        changed()
        writeBreadcrumb()
        // Last, and exactly once. It resumes a continuation, so a second call
        // is a crash rather than a duplicate notification — and the waiter
        // should wake to a list that has already settled.
        completion?(failure)
    }

    /// A row for something that failed before it could start.
    private func record(kind: Kind, subtitle: String, failure: FilaFailure) {
        let operation = Operation(
            kind: kind,
            title: kind.runningTitle,
            subtitle: subtitle,
            state: .finished(failure),
            affected: [],
            control: nil,
            undo: nil
        )
        append(operation)
        announce(operation)
    }

    private func append(_ operation: Operation) {
        place(operation)
        trimFinished()
        changed()
        writeBreadcrumb()
    }

    /// Running rows stay at the top, newest first; everything else sits below
    /// them, also newest first. One rule, so a job that failed before it could
    /// start cannot jump over three transfers that are still copying.
    private func place(_ operation: Operation) {
        let index = operation.isRunning ? 0 : operations.prefix(while: \.isRunning).count
        operations.insert(operation, at: index)
    }

    private func trimFinished() {
        var kept = 0
        operations.removeAll { operation in
            guard !operation.isRunning else { return false }
            kept += 1
            return kept > Self.finishedLimit
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .filaSidebarChanged, object: nil)
    }

    // MARK: - Announcing

    /// Feedback for operations whose caller has not taken ownership of it:
    ///
    /// - Every failure is an alert with its reason and a Close button.
    /// - A cancellation says nothing. The user cancelled it; they know.
    /// - A success that can be undone is a toast carrying the undo, because an
    ///   offer nobody sees is not an offer.
    /// - `.successOnly`, instant and archive successes get a toast; the archive progress card
    ///   dismisses without announcing the same completion again.
    /// - Everything else already said it, in the transfers list, while it ran.
    private func announce(_ operation: Operation) {
        guard operation.feedback != .silent else { return }
        if let failure = operation.failure {
            guard operation.feedback == .automatic else { return }
            FeedbackAlert.show(FailureText.title(for: failure), message: FailureText.summary(for: failure))
            return
        }
        guard operation.succeeded else { return }
        if let undo = operation.undo {
            Toast.show(
                operation.kind.completionTitle,
                action: Toast.Action(title: undo.title) { [weak self] in self?.undo(operation) }
            )
        } else if operation.feedback == .successOnly || operation.kind.isInstant || operation.kind == .compress || operation.kind == .extract {
            Toast.show(operation.kind.completionTitle)
        }
    }

    // MARK: - Dying with the app

    /// `filad` runs a job for the connection that asked for it, and cancels
    /// every one of a peer's jobs when the peer goes away. So a copy does not
    /// survive the app being killed: it stops, half done, with nothing left to
    /// report it.
    ///
    /// No code runs at kill time, so the list of what was in flight is written
    /// whenever it changes and read back on the next launch. It is a
    /// breadcrumb, not a queue — nothing here can resume anything, and saying
    /// it stopped is the whole point.
    private func writeBreadcrumb() {
        let inFlight = operations
            .filter { $0.isRunning && !$0.kind.isInstant }
            .map { [$0.kind.rawValue, $0.title, $0.subtitle] }
        let defaults = UserDefaults.standard
        if inFlight.isEmpty {
            defaults.removeObject(forKey: Self.breadcrumbKey)
        } else {
            defaults.set(inFlight, forKey: Self.breadcrumbKey)
        }
    }

    private func seedInterrupted() {
        let defaults = UserDefaults.standard
        let stored = defaults.array(forKey: Self.breadcrumbKey) as? [[String]] ?? []
        guard !stored.isEmpty else { return }
        defaults.removeObject(forKey: Self.breadcrumbKey)
        operations = stored.compactMap { row in
            guard row.count == 3, let kind = Kind(rawValue: row[0]) else { return nil }
            return Operation(
                kind: kind,
                title: row[1],
                subtitle: row[2],
                state: .interrupted,
                affected: [],
                    control: nil,
                undo: nil
            )
        }
        guard !operations.isEmpty else { return }
        // Deferred one hop so the scene has a window to present an alert from.
        Task { [weak self] in
            guard let self, !self.operations.isEmpty else { return }
            FeedbackAlert.show(
                String(localized: "Task stopped"),
                message: String(localized: "Fila closed before the task finished. Start it again.")
            )
        }
    }

    // MARK: - Inverses

    /// The job identity and canonical origin survive cross-volume copying.
    /// Matching both keeps an old Undo from picking up a later deletion.
    private func putBack(_ origins: [String], identity: UUID) async throws {
        var byVolume: [String: [String]] = [:]
        for origin in origins {
            let directory = (origin as NSString).deletingLastPathComponent
            let volume = try await session.perform(retryOnDisconnect: true) {
                try await $0.volumeInfo(for: directory)
            }
            byVolume[volume.mountPoint, default: []].append(origin)
        }
        for (mountPoint, group) in byVolume {
            let found = try await locate(group, identity: identity, inTrashOf: mountPoint)
            for origin in group {
                guard let source = found[origin] else { throw FilaFailure(code: .notFound, path: origin) }
                try await restore(source, to: origin, identity: identity)
            }
        }
    }

    private func locate(_ origins: [String], identity: UUID, inTrashOf mountPoint: String) async throws -> [String: String] {
        guard let backend = session.hello?.backend else { return [:] }
        let directory = SidebarLocation.trashDirectory(backend: backend, volume: mountPoint)
        let wanted = Set(origins)
        var found: [String: String] = [:]
        for try await page in DirectoryReader.pages(in: directory, session: session) {
            for node in page {
                let path = Self.join(directory, node.name)
                do {
                    let recorded = try await session.perform(retryOnDisconnect: true) {
                        try await $0.extendedAttribute(FilaTrash.jobAttribute, at: path)
                    }
                    guard recorded == Data(identity.uuidString.utf8) else { continue }
                    let data = try await session.perform(retryOnDisconnect: true) {
                        try await $0.extendedAttribute(FilaTrash.originAttribute, at: path)
                    }
                    guard let origin = String(data: data, encoding: .utf8), wanted.contains(origin) else { continue }
                    // Ambiguous records must never pick an arbitrary file.
                    guard found[origin] == nil else { throw FilaFailure(code: .invalidRequest, path: path) }
                    found[origin] = path
                } catch let failure as FilaFailure where failure.systemError == ENOATTR || failure.code == .notFound {
                    continue
                }
            }
        }
        return found
    }

    /// Put Back from inside the trash: each item goes to the path the job
    /// wrote on it (`FilaTrash.originAttribute`), and the note comes off once
    /// it is home. An item without the note fails with `ENOATTR` naming it —
    /// the daemon's own answer for a missing attribute, kept distinct from a
    /// link that dropped so the app does not call a disconnect "no record".
    func putBack(trashed paths: [String]) async throws {
        // One item's refusal is no reason to leave the rest in the trash: every
        // item is tried, and the first refusal is what the caller hears about.
        var firstFailure: Error?
        for path in paths {
            do {
                let data = try await session.perform(retryOnDisconnect: true) {
                    try await $0.extendedAttribute(FilaTrash.originAttribute, at: path)
                }
                guard let origin = String(data: data, encoding: .utf8), origin.hasPrefix("/") else {
                    throw FilaFailure(code: .operationFailed, systemError: ENOATTR, path: path)
                }
                try await restore(path, to: origin)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    private func restore(_ path: String, to original: String, identity: UUID? = nil) async throws {
        let outcome = try await awaitJob(
            JobRequest(kind: .restore, sources: [path], destination: (original as NSString).deletingLastPathComponent, trashID: identity),
            kind: .move, subtitle: Self.describe([path], destination: original), feedback: .silent
        )
        guard outcome.code == .success else { throw outcome }
    }

    // MARK: - Text

    static func describe(_ paths: [String], destination: String? = nil) -> String {
        let what = paths.count == 1
            ? (paths[0] as NSString).lastPathComponent
            : String(localized: "\(paths.count) items")
        guard let destination else { return what }
        return what + " → " + destination
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }
}

extension OperationCenter.Kind {
    /// Present tense, for the row while it runs.
    var runningTitle: String {
        switch self {
        case .copy: return String(localized: "Copying…")
        case .move: return String(localized: "Moving…")
        case .trash: return String(localized: "Moving to Trash…")
        case .delete: return String(localized: "Deleting…")
        case .compress: return String(localized: "Compressing…")
        case .extract: return String(localized: "Extracting…")
        case .rename: return String(localized: "Renaming…")
        case .create: return String(localized: "Creating…")
        case .attributes: return String(localized: "Changing Attributes…")
        case .download: return String(localized: "Downloading…")
        }
    }

    /// Past tense, for the toast that says it is over.
    var completionTitle: String {
        switch self {
        case .copy: return String(localized: "Copied")
        case .move: return String(localized: "Moved")
        case .trash: return String(localized: "Moved to Trash")
        case .delete: return String(localized: "Deleted")
        case .compress: return String(localized: "Compressed")
        case .extract: return String(localized: "Extracted")
        case .rename: return String(localized: "Renamed")
        case .create: return String(localized: "Created")
        case .attributes: return String(localized: "Attributes changed")
        case .download: return String(localized: "Downloaded")
        }
    }

    /// Every one of these is a symbol the app already ships, which is the point:
    /// a symbol added after iOS 15 draws nothing at all — no warning from the
    /// compiler, no error at runtime, just a gap where the icon was. Reusing
    /// what the menus already use is how that stays impossible.
    var symbol: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .move: return "scissors"
        case .trash: return "trash"
        case .delete: return "trash"
        case .compress: return "doc.zipper"
        case .extract: return "arrow.down.to.line"
        case .rename: return "pencil"
        case .create: return "plus"
        case .attributes: return "doc.badge.gearshape"
        case .download: return "arrow.down.circle"
        }
    }
}
