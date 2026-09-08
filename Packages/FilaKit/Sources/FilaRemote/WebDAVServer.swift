import FilaProtocol
import Foundation
import Network
import NIOCore
import NIOHTTP1
import NIOTransportServices

/// A WebDAV server over the device's filesystem, so a Mac can mount the phone
/// in Finder and a browser can list and download from it.
///
/// NIO owns HTTP framing, connection backpressure, and the Network.framework
/// transport. The DAV adapter owns authentication and delegates filesystem
/// decisions to the existing backend.
///
/// **What it is not.** It is not a way around `filad`. Every path it touches
/// goes through `RemoteFileService`, backed by the daemon or the selected
/// in-process file service. With the daemon, the app runs as `mobile` and
/// cannot itself open privileged files. In either backend — the
/// part that matters — a write that skipped the daemon would skip `FilaGuard`
/// with it. A DELETE arriving from the network is checked by exactly the same
/// code as a swipe in the browser.
///
/// **Security.** Off until the user starts it, no anonymous mode at any
/// setting, and a password they choose with no default. Basic authentication
/// over plain HTTP is weak by construction, which is why the listener refuses
/// cellular interfaces and why the address it prints is a LAN address: the
/// threat model is a home network, and the honest statement of it is in the
/// settings screen rather than in a comment here.
public final class WebDAVServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var port: UInt16
        public var username: String
        /// Required. There is no anonymous mode and no default password: this
        /// server hands out `/`, and a default would be a published credential.
        public var password: String
        /// The subtree that is served. `/` in the app; a scratch directory in
        /// the harness, where it is also what proves an escape is refused.
        ///
        /// **Must already be canonical** — `/private/var/…`, not `/var/…`. It
        /// is compared against the canonical paths the daemon reports, and an
        /// uncanonical root would match none of them.
        public var root: String
        /// Bonjour makes the device appear in Finder's sidebar. It reaches the
        /// local link and no further, which is the same boundary as the rest of
        /// this feature.
        public var advertisesBonjour: Bool
        public var serviceName: String
        /// The directory holding the browser frontend: `index.html` plus the
        /// assets it references under `/_fila/`. Built separately from
        /// `WebUI/` and copied into the app bundle; this server only reads it.
        /// `nil` answers a browser's directory GET with 404 and leaves the DAV
        /// protocol untouched.
        public var webRoot: URL?

        public init(
            port: UInt16,
            username: String,
            password: String,
            root: String = "/",
            advertisesBonjour: Bool = true,
            serviceName: String = "Fila",
            webRoot: URL? = nil
        ) {
            self.port = port
            self.username = username
            self.password = password
            self.root = root
            self.advertisesBonjour = advertisesBonjour
            self.serviceName = serviceName
            self.webRoot = webRoot
        }
    }

    public enum Status: Sendable, Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        /// The listener gave up. The port being taken is the one a user hits.
        case failed(String)
    }

    public struct LogEntry: Sendable, Identifiable, Equatable {
        public let id = UUID()
        public let date: Date
        public let text: String
    }

    public enum StartFailure: Error, Equatable {
        case passwordRequired
        case invalidPort
    }

    /// How many connections are served at once. Finder opens a handful and a
    /// browser two; the cap is here so that whoever else can reach the port
    /// cannot make the app hold a thousand descriptors.
    static let connectionLimit = 32

    /// The log is a window, not a history — it is read on a settings screen and
    /// nowhere else.
    static let logLimit = 200

    private let service: RemoteFileService
    private let ioTimeout: TimeAmount
    private static let eventLoops = NIOTSEventLoopGroup(loopCount: 1, defaultQoS: .utility)
    private let lock = NSLock()

    private var listener: NWListener?
    private var listenerChannel: Channel?
    private var connections: [ObjectIdentifier: Channel] = [:]
    private var generation = UUID()
    private var storedStatus: Status = .stopped
    private var storedLog: [LogEntry] = []

    /// Called after a state change, outside the state lock. The callback may
    /// run on a NIO event loop or the caller's thread; the UI hops to MainActor.
    public var onChange: (@Sendable () -> Void)?

    public convenience init(service: RemoteFileService) {
        self.init(service: service, ioTimeout: .seconds(HTTPConnection.readTimeoutSeconds))
    }

    init(service: RemoteFileService, ioTimeout: TimeAmount) {
        self.service = service
        self.ioTimeout = ioTimeout
    }

    deinit {
        listenerChannel?.close(promise: nil)
        for channel in connections.values {
            channel.close(promise: nil)
        }
    }

    // MARK: - Lifecycle

    public var status: Status {
        lock.lock()
        defer { lock.unlock() }
        return storedStatus
    }

    public var log: [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storedLog
    }

    public var isRunning: Bool {
        if case .running = status {
            return true
        }
        return false
    }

    public func start(_ configuration: Configuration) throws {
        guard !configuration.password.isEmpty else { throw StartFailure.passwordRequired }
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else { throw StartFailure.invalidPort }

        stop()

        let parameters = NWParameters.tcp
        // A file manager's port has no business on the cell network, and a
        // listener that answers there is one an operator's CGNAT peer can
        // reach. Prohibiting the interface is the cheap half of "LAN only";
        // the password is the half that has to hold.
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            // A peer that vanishes mid-mount — a laptop closing its lid — would
            // otherwise hold a slot in `connectionLimit` for as long as the
            // server runs.
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            set(status: .failed(error.localizedDescription))
            throw error
        }
        if configuration.advertisesBonjour {
            listener.service = NWListener.Service(name: configuration.serviceName, type: "_webdav._tcp")
        }

        let run = UUID()
        let nonces = DigestNonces()
        lock.lock()
        generation = run
        self.listener = listener
        storedStatus = .starting
        lock.unlock()
        changed()

        NIOTSListenerBootstrap(group: Self.eventLoops)
            .serverChannelInitializer { [weak self] channel in
                guard let self else { return channel.eventLoop.makeFailedFuture(HTTPFailure.closed) }
                lock.lock()
                defer { self.lock.unlock() }
                guard generation == run, self.listener != nil else {
                    return channel.eventLoop.makeFailedFuture(HTTPFailure.closed)
                }
                // NIO owns the listener before binding completes. Keep its channel
                // now so stop() can also close a listener that is still starting.
                listenerChannel = channel
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .childChannelOption(NIOTSChannelOptions.maximumReceiveLength, value: HTTPConnection.chunkByteCount)
            .childChannelOption(
                ChannelOptions.writeBufferWaterMark,
                value: .init(low: HTTPConnection.chunkByteCount, high: 2 * HTTPConnection.chunkByteCount)
            )
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.eventLoop.makeFailedFuture(HTTPFailure.closed) }
                return channel.eventLoop.makeCompletedFuture {
                    try self.accept(channel, run: run, configuration: configuration, nonces: nonces)
                }
            }
            .withNWListener(listener)
            .whenComplete { [weak self] result in
                guard let self else {
                    if case let .success(channel) = result {
                        channel.close(promise: nil)
                    }
                    return
                }
                lock.lock()
                guard generation == run, self.listener != nil else {
                    lock.unlock()
                    if case let .success(channel) = result {
                        channel.close(promise: nil)
                    }
                    return
                }
                switch result {
                case let .success(channel):
                    listenerChannel = channel
                    storedStatus = .running(port: listener.port?.rawValue ?? configuration.port)
                    lock.unlock()
                    channel.closeFuture.whenComplete { [weak self] _ in self?.listenerClosed(run: run) }
                    note("Sharing started on port \(listener.port?.rawValue ?? configuration.port).")
                case let .failure(error):
                    self.listener = nil
                    listenerChannel = nil
                    storedStatus = .failed(error.localizedDescription)
                    lock.unlock()
                    note("Sharing stopped unexpectedly. Start sharing again.")
                }
                changed()
            }
    }

    public func stop() {
        lock.lock()
        generation = UUID()
        let channel = listenerChannel
        let open = Array(connections.values)
        listener = nil
        listenerChannel = nil
        connections.removeAll()
        let wasRunning = storedStatus != .stopped
        storedStatus = .stopped
        lock.unlock()
        channel?.close(promise: nil)
        for connection in open {
            connection.close(promise: nil)
        }
        if wasRunning {
            note("Sharing stopped.")
        }
        changed()
    }

    private func listenerClosed(run: UUID) {
        lock.lock()
        guard generation == run else { lock.unlock(); return }
        generation = UUID()
        listener = nil
        listenerChannel = nil
        let open = Array(connections.values)
        connections.removeAll()
        storedStatus = .failed("Sharing stopped unexpectedly. Start sharing again.")
        lock.unlock()
        for channel in open {
            channel.close(promise: nil)
        }
        changed()
    }

    public func clearLog() {
        lock.lock()
        storedLog.removeAll()
        lock.unlock()
        changed()
    }

    // MARK: - Connections

    private func accept(_ channel: Channel, run: UUID, configuration: Configuration, nonces: DigestNonces) throws {
        lock.lock()
        let accepted = generation == run && listener != nil && connections.count < Self.connectionLimit
        if accepted {
            connections[ObjectIdentifier(channel)] = channel
        }
        lock.unlock()
        guard accepted else { throw HTTPFailure.closed }
        channel.closeFuture.whenComplete { [weak self] _ in self?.forget(channel) }

        var limits = NIOHTTPDecoderLimitConfiguration()
        limits.maxHeaderFieldSize = HTTPConnection.maximumHeadByteCount
        limits.maxHeaderListSize = HTTPConnection.maximumHeadByteCount
        limits.maxHeaderFieldCount = 100
        try channel.pipeline.syncOperations.configureHTTPServerPipeline(
            withPipeliningAssistance: false,
            withEncoderConfiguration: .init(),
            withDecoderLimitConfiguration: limits
        )
        let conversation = try NIOAsyncChannel<HTTPServerRequestPart, Never>(
            wrappingChannelSynchronously: channel,
            configuration: .init(backPressureStrategy: .init(lowWatermark: 2, highWatermark: 4))
        )
        let peer = channel.remoteAddress?.ipAddress ?? "A device"
        note("\(peer) connected.")
        let handler = WebDAVHandler(
            service: service, configuration: configuration, nonces: nonces,
            log: { [weak self] line in self?.note("\(peer) \(line)") }
        )
        let ioTimeout = ioTimeout
        Task {
            try? await conversation.executeThenClose { inbound, _ in
                await handler.serve(HTTPConnection(inbound: inbound, channel: channel, ioTimeout: ioTimeout))
            }
        }
    }

    private func forget(_ channel: Channel) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(channel))
        lock.unlock()
    }

    // MARK: - State

    private func set(status: Status) {
        lock.lock()
        storedStatus = status
        lock.unlock()
        changed()
    }

    /// One line for the connection log the settings screen shows. This is the
    /// only place a user finds out that something reached the port.
    func note(_ text: String) {
        lock.lock()
        storedLog.append(LogEntry(date: Date(), text: text))
        if storedLog.count > Self.logLimit {
            storedLog.removeFirst(storedLog.count - Self.logLimit)
        }
        lock.unlock()
        changed()
    }

    private func changed() {
        onChange?()
    }
}
