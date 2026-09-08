import Foundation
import NIOCore
import NIOHTTP1

enum HTTPFailure: Error {
    case closed
    case malformed
    case tooLarge
}

/// A single sequential DAV conversation over NIO's parsed HTTP messages.
/// NIO owns HTTP framing and demand-driven socket reads/writes. Neither an
/// upload nor a download is collected into a complete in-memory body.
final class HTTPConnection {
    static let chunkByteCount = 256 * 1_024
    static let maximumHeadByteCount = 64 * 1_024
    static let readTimeoutSeconds: Int64 = 60

    private var inbound: NIOAsyncChannelInboundStream<HTTPServerRequestPart>.AsyncIterator
    private let channel: Channel
    private let ioTimeout: TimeAmount
    private var responseStarted = false

    init(
        inbound: NIOAsyncChannelInboundStream<HTTPServerRequestPart>,
        channel: Channel,
        ioTimeout: TimeAmount = .seconds(readTimeoutSeconds)
    ) {
        self.inbound = inbound.makeAsyncIterator()
        self.channel = channel
        self.ioTimeout = ioTimeout
    }

    func close() { channel.close(promise: nil) }

    func readRequest() async throws -> HTTPRequest? {
        while let part = try await nextPart() {
            switch part {
            case let .head(head): return HTTPRequest(head)
            case .end: continue
            case .body: throw HTTPFailure.malformed
            }
        }
        return nil
    }

    func drainBody(count: Int, into sink: (Data) throws -> Void) async throws {
        try await drain(expectedCount: count, into: sink)
    }

    func drainChunkedBody(into sink: (Data) throws -> Void) async throws {
        try await drain(expectedCount: nil, into: sink)
    }

    private func drain(expectedCount: Int?, into sink: (Data) throws -> Void) async throws {
        var received = 0
        while let part = try await nextPart() {
            switch part {
            case let .body(buffer):
                guard buffer.readableBytes <= Int.max - received else { throw HTTPFailure.tooLarge }
                received += buffer.readableBytes
                if let expectedCount, received > expectedCount { throw HTTPFailure.malformed }
                try sink(Data(buffer.readableBytesView))
            case .end:
                if let expectedCount, received != expectedCount { throw HTTPFailure.closed }
                return
            case .head: throw HTTPFailure.malformed
            }
        }
        throw HTTPFailure.closed
    }

    // Await the transport's write promise, not merely enqueueing into an
    // AsyncChannel writer. This keeps one file chunk in flight and makes the
    // final response reach the socket before executeThenClose cancels it.
    func write(_ head: HTTPResponseHead) async throws {
        if head.status.code >= 200 {
            guard !responseStarted else { throw HTTPFailure.malformed }
            responseStarted = true
        }
        try await send(.head(head))
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await send(.body(.byteBuffer(ByteBuffer(bytes: data))))
    }

    func writeChunk(_ data: Data) async throws { try await write(data) }

    func endChunks() async throws { try await finishResponse() }

    func finishResponse() async throws {
        guard responseStarted else { return }
        responseStarted = false
        try await send(.end(nil))
    }
    private func nextPart() async throws -> HTTPServerRequestPart? {
        try await withIOTimeout { try await self.inbound.next() }
    }

    private func send(_ part: HTTPServerResponsePart) async throws {
        try await withIOTimeout { try await self.channel.writeAndFlush(part).get() }
    }

    /// Bound a stalled socket wait, but never a backend operation. A large
    /// COPY may legitimately spend minutes in copyfile without network bytes.
    /// Cancelling the channel completes the pending read/write with an error.
    private func withIOTimeout<Value>(_ operation: () async throws -> Value) async throws -> Value {
        let deadline = channel.eventLoop.scheduleTask(in: ioTimeout) { [channel] in
            channel.close(promise: nil)
        }
        defer { deadline.cancel() }
        return try await operation()
    }

}
