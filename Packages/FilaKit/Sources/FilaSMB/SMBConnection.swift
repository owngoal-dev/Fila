import FilaBackendKit
import FilaLog
import Foundation
import SMBClient

/// One authenticated session to one share, and the rules every request on
/// it follows.
///
/// **One request at a time.** The vendor's session numbers its messages and
/// serialises its transport, but neither is safe to interleave from two
/// tasks, so every request — a directory page, a read, a close — waits for
/// the one before it. A listing does not hold the turn between pages: the
/// handle stays open on the server while another request runs, which is
/// what lets a details call land while a large directory streams.
///
/// **A request that outlives its budget retires the session.** The vendor
/// has no cancel and no timeout: a request whose reply never comes would
/// wait forever, and a task cancelled while it waits cannot make it stop.
/// Closing the TCP connection can, so that is what a timeout and a
/// cancellation do. Every handle opened on that session is then gone; the
/// next request opens a fresh session, and whoever held a handle hears
/// `disconnected` and starts over.
actor SMBConnection {
    struct Configuration: Sendable {
        var host: String
        var port: Int
        var share: String
        var domain: String?
        var username: String?
        var password: String?
    }

    /// A file or directory open on one session. Useless after that session
    /// was retired, which is why it remembers which one.
    struct Handle: @unchecked Sendable {
        let client: SMBClient
        let fileId: Data
        let size: UInt64
    }

    nonisolated let configuration: Configuration
    /// How long a connection may take to come up, and a request to answer.
    nonisolated let connectTimeout: TimeInterval
    private(set) var requestTimeout: TimeInterval

    /// For tests that need a request to outlive its budget on a fast
    /// network; production keeps the one it was built with.
    func setRequestTimeout(_ timeout: TimeInterval) {
        requestTimeout = timeout
    }

    private var client: SMBClient?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lostHandlers: [UUID: @Sendable (SMBError) -> Void] = [:]

    init(configuration: Configuration, connectTimeout: TimeInterval = 20, requestTimeout: TimeInterval = 30) {
        self.configuration = configuration
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
    }

    /// Told when the session is retired for a reason other than the caller
    /// asking: a timeout, a dropped connection. Observation ends its
    /// streams from here.
    func onSessionLost(_ handler: @escaping @Sendable (SMBError) -> Void) -> UUID {
        let token = UUID()
        lostHandlers[token] = handler
        return token
    }

    /// `onSessionLost` under a caller-owned token, installed once: a
    /// second call with the same token keeps the first handler, so an
    /// owner needs no state of its own to make the installation idempotent.
    func installLostHandler(_ token: UUID, _ handler: @escaping @Sendable (SMBError) -> Void) {
        guard lostHandlers[token] == nil else { return }
        lostHandlers[token] = handler
    }

    func removeLostHandler(_ token: UUID) {
        lostHandlers[token] = nil
    }

    /// Closes `handle` on the server whatever the caller's cancellation
    /// state. A close is cleanup: the transfer or listing that was
    /// cancelled must not leave its handle open for the life of the
    /// session, so the request runs in a task of its own that inherits no
    /// cancellation, and the caller waits for it. A handle on a retired
    /// session is already closed and fails silently.
    nonisolated func closeHandle(_ handle: Handle) async {
        let close = Task.detached { [self] in
            _ = try await self.perform("close", on: handle) { client in
                try await client.session.close(fileId: handle.fileId)
            }
        }
        _ = try? await close.value
    }

    /// Closes the session, if any, and tells nobody: what the owner does
    /// when the backend is edited away or removed.
    func close() {
        guard let client else { return }
        self.client = nil
        client.session.disconnect()
    }

    // MARK: - Requests

    /// Runs `body` against the connected session, connecting first if
    /// needed, as the one request in flight. `path` is what an error is
    /// reported against.
    func perform<T: Sendable>(
        _ operation: String,
        path: String? = nil,
        _ body: @escaping @Sendable (SMBClient) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        await acquire()
        defer { release() }
        let client = try await connectedClient()
        return try await run(operation, path: path, timeout: requestTimeout, on: client) { try await body(client) }
    }

    /// `perform` against the session `handle` was opened on. A handle from
    /// a retired session fails as `disconnected` without touching the
    /// wire.
    func perform<T: Sendable>(
        _ operation: String,
        on handle: Handle,
        path: String? = nil,
        _ body: @escaping @Sendable (SMBClient) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        await acquire()
        defer { release() }
        guard let client, client === handle.client else { throw SMBError.disconnected }
        return try await run(operation, path: path, timeout: requestTimeout, on: client) { try await body(client) }
    }

    // MARK: - Session

    private func connectedClient() async throws -> SMBClient {
        if let client { return client }
        let configuration = configuration
        let client = SMBClient(host: configuration.host, port: configuration.port)
        do {
            try await run("connect", path: nil, timeout: connectTimeout, on: client) {
                try await client.login(
                    username: configuration.isGuest ? nil : configuration.username,
                    password: configuration.isGuest ? nil : configuration.password,
                    domain: configuration.domain?.isEmpty == false ? configuration.domain : nil
                )
                try await client.connectShare(configuration.share)
            }
        } catch let error as SMBError {
            client.session.disconnect()
            // The only name in play here is the share's: a refusal of it
            // arrives as BAD_NETWORK_NAME from Windows and as
            // OBJECT_NAME_NOT_FOUND from some other servers.
            switch error {
            case .shareNotFound, .notFound:
                throw SMBError.shareNotFound(configuration.share)
            default:
                throw error
            }
        }
        // The handler is stored on the client itself, so a strong capture
        // of `client` would keep every retired session alive for good.
        client.onDisconnected = { [weak self, weak client] error in
            guard let client else { return }
            Task { await self?.sessionDropped(client, error: error) }
        }
        self.client = client
        FilaLog.info("smb: connected to \(configuration.host):\(configuration.port)/\(configuration.share)")
        return client
    }

    private enum Outcome<T: Sendable>: Sendable {
        case value(T)
        case failed(Error)
        case timedOut
    }

    /// `body` against a deadline. The vendor's awaits do not observe task
    /// cancellation, so both a timeout and a cancellation of the caller
    /// close the connection to bring `body` back, and nothing returns until
    /// it has: the turn is not released while a request may still touch
    /// the session.
    private func run<T: Sendable>(
        _ operation: String,
        path: String?,
        timeout: TimeInterval,
        on client: SMBClient,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: Outcome<T>.self) { group in
            group.addTask {
                do { return .value(try await body()) } catch { return .failed(error) }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timedOut
            }
            let first: Outcome<T>?
            do {
                first = try await group.next()
            } catch {
                // Only the sleeper throws, and only for cancellation.
                retire(client, reason: .disconnected, announce: false)
                group.cancelAll()
                await group.drain()
                throw CancellationError()
            }
            switch first {
            case let .value(value):
                group.cancelAll()
                await group.drain()
                return value
            case let .failed(error):
                group.cancelAll()
                await group.drain()
                let mapped = SMBError.map(error, path: path, operation: operation)
                if mapped.retiresSession {
                    retire(client, reason: mapped, announce: true)
                }
                throw mapped
            case .timedOut:
                let failure = SMBError.timedOut(operation: operation)
                retire(client, reason: failure, announce: true)
                group.cancelAll()
                await group.drain()
                FilaLog.warning("smb: \(operation) timed out after \(Int(timeout))s; session retired")
                throw failure
            case nil:
                throw SMBError.disconnected
            }
        }
    }

    private func retire(_ client: SMBClient, reason: SMBError, announce: Bool) {
        client.session.disconnect()
        guard self.client === client else { return }
        self.client = nil
        if announce {
            for handler in lostHandlers.values { handler(reason) }
        }
    }

    private func sessionDropped(_ client: SMBClient, error: Error) {
        guard self.client === client else { return }
        let mapped = SMBError.map(error, path: nil, operation: "session")
        FilaLog.warning("smb: session to \(configuration.host) dropped: \(error)")
        retire(client, reason: mapped.retiresSession ? mapped : .disconnected, announce: true)
    }

    // MARK: - Setup

    /// The disk shares `configuration.host` offers the account, for the
    /// setup screen. Its own short-lived session, logged off afterwards;
    /// the share in `configuration` is not connected. Servers that refuse
    /// enumeration to this account throw the refusal, and the screen lets
    /// the user type a name instead.
    static func listShares(_ configuration: Configuration, timeout: TimeInterval = 20) async throws -> [String] {
        let connection = SMBConnection(configuration: configuration, connectTimeout: timeout, requestTimeout: timeout)
        let client = SMBClient(host: configuration.host, port: configuration.port)
        defer { client.session.disconnect() }
        return try await connection.run("list shares", path: nil, timeout: timeout, on: client) {
            try await client.login(
                username: configuration.isGuest ? nil : configuration.username,
                password: configuration.isGuest ? nil : configuration.password,
                domain: configuration.domain?.isEmpty == false ? configuration.domain : nil
            )
            let shares = try await client.listShares()
            try? await client.logoff()
            return shares
                .filter { $0.type.rawValue & 0x0FFF_FFFF == Share.ShareType.diskTree.rawValue && !$0.name.hasSuffix("$") }
                .map(\.name)
        }
    }

    // MARK: - Turn taking

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            // The turn passes directly; `busy` stays true for the next.
            waiters.removeFirst().resume()
        }
    }
}

extension SMBConnection.Configuration {
    var isGuest: Bool { username?.isEmpty != false }
}

private extension ThrowingTaskGroup {
    /// Waits for every child, ignoring what they return: what a cancelled
    /// or superseded child is drained with.
    mutating func drain() async {
        while true {
            do {
                guard try await next() != nil else { return }
            } catch {
                continue
            }
        }
    }
}
