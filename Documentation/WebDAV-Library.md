# WebDAV library evaluation

Reviewed upstream sources on 2026-09-05. Fila uses SwiftNIO and
NIOTransportServices for HTTP parsing, serialization and Network.framework
transport. These dependencies link only through FilaRemote in the app.

`Packages/FilaKit/Package.swift` asks for a floor, not an exact version:
`from: "2.102.0"` for swift-nio and `from: "1.28.0"` for
swift-nio-transport-services. Those are minimums — the APIs used here exist at
that version, and a patch release is not a decision worth re-taking. The
version actually built is whatever `Packages/FilaKit/Package.resolved` pins;
read it there rather than from this page.

Fila needs an HTTP implementation with bounded request/response streaming while
every filesystem operation continues through `RemoteFileService`. Reads use a
descriptor returned by the backend; PUT writes to a descriptor for a temporary
beside the destination and publishes through the backend. A library that opens
paths directly cannot replace that adapter.

| Candidate | Fit | Remaining work |
| --- | --- | --- |
| Apple SwiftNIO `NIOHTTP1` with `NIOTransportServices` | Adopted. Transport Services supports iOS 12+, wraps an existing `NWListener`, exposes Network parameters, and provides channel backpressure. | DAV methods, authentication, path checks and publication remain app-owned. Device mounting and binary size require separate validation. |
| FlyingFox | Swift package supporting iOS 13+, with async streaming bodies and no external package dependencies. A descriptor can feed its buffered sequence API. | Its public server API does not provide the present Network interface exclusion or pre-authentication connection admission hook. Preserving those policies requires upstream API work or a fork. It supplies HTTP, not DAV semantics. |
| GCDWebServer / GCDWebDAVServer | Includes an actual DAV implementation. | Upstream is archived. Its DAV implementation performs filesystem operations through paths and `NSFileManager`; replacing these with the async descriptor/backend adapter requires maintaining a substantial fork. Not selected. |

Sources: [NIO listener bootstrap](https://github.com/apple/swift-nio-transport-services/blob/main/Sources/NIOTransportServices/NIOTSListenerBootstrap.swift),
[NIO transport package](https://github.com/apple/swift-nio-transport-services/blob/main/Package.swift),
[FlyingFox package](https://github.com/swhitty/FlyingFox/blob/main/Package.swift),
[FlyingFox body sequence](https://github.com/swhitty/FlyingFox/blob/main/FlyingFox/Sources/HTTPBodySequence.swift),
[FlyingFox server](https://github.com/swhitty/FlyingFox/blob/main/FlyingFox/Sources/HTTPServer.swift),
[GCDWebServer](https://github.com/swisspol/GCDWebServer),
[GCDWebDAVServer implementation](https://github.com/swisspol/GCDWebServer/blob/master/GCDWebDAVServer/GCDWebDAVServer.m).

## Implementation boundary

1. `NIOHTTP1` and `NIOTransportServices` belong to **FilaRemote only**. Their package
   dependency graph must never reach FilaProtocol, FilaFileOps, FilaLog or filad.
   The rationale is replacing our HTTP parser, chunk framing and socket lifecycle
   with a maintained implementation; a complete DAV library replacement remains
   unresolved. No binary-size claim has been measured yet.
2. Keep `WebDAVServer.Configuration`, status/log callbacks and
   `RemoteFileService` unchanged. Wrap the configured `NWListener` so Bonjour and
   cellular exclusion retain their current behavior. Enforce the 32-connection
   admission limit before parsing requests.
3. `HTTPConnection` consumes NIO request/body/end messages. It uses
   bounded read demand and awaits each response write. It does not bridge to an
   unbounded `AsyncStream` or collect upload/download bodies into `Data`.
   Descriptor ownership must end on completion, cancellation and connection loss.

DAV routing, digest/basic authentication, served-root checks, deletion policy
and atomic publication stay in the application adapter. The production parser
and serializer use NIO types directly. NIOEmbedded is used only in synchronous
parser tests: its OS-thread affinity makes it unsuitable for framing on
arbitrary Swift concurrency executors.

WebDAV DELETE permanently removes items, independently of the app's trash
preference. The WebUI confirms that deletion includes folder contents and cannot
be undone; it has no trash or Put Back workflow.

LOCK/UNLOCK are not implemented. OPTIONS omits those methods and class 2;
PROPFIND reports no supported locks; LOCK/UNLOCK receive 405; mutations with
a DAV If condition receive 501. Ordinary unconditional transfer remains
available.

## Browser integration and limits

One listener serves both DAV and the bundled browser UI with the same mandatory
password. Directory GET returns the application; it uses native DAV methods.
There is no second port or separate filesystem API. Browser PUT requests use
`If-None-Match: *`, and the backend publishes with an exclusive rename so an
upload race cannot overwrite another file. Existing native DAV replacement
behavior remains atomic through `replaceItem`.

Origin-bearing requests must match the listener's HTTP authority; no CORS
permission is emitted. Served files are attachments with a sandbox content
security policy so uploaded HTML cannot execute with the browser application's
credentials. This is still unencrypted LAN HTTP. There is no lock-based
mutual exclusion against other DAV clients or local filesystem writers.

NIOTransportServices wraps the configured NWListener, retaining Bonjour and
cellular interface exclusion. Admission is capped at 32 connections. Receives
are capped at 256 KiB, async inbound demand has a four-part high watermark,
and outbound channel watermarks apply backpressure. Individual socket read/write
waits time out after 60 seconds; filesystem operations have no network-idle
deadline. Each server run has separate nonces, and stale completion
callbacks cannot update a restarted listener.

Hummingbird 2 server APIs require newer iOS availability than Fila's iOS 15
floor; adopting its older 1.x line would choose an older framework solely for
its name. Vapor supports the floor, but its public HTTPServer transport uses
BSD ServerBootstrap and adds a substantially broader dependency graph. The
chosen lower-level NIO transport preserves the application's existing Network
interface policy and descriptor adapter without either framework fork.
