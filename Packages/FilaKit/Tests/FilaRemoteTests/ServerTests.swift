import Darwin
import FilaProtocol
import Foundation
import Testing
import NIOCore

@testable import FilaRemote

/// A running server on loopback, and a client that can speak the verbs
/// `URLSession` has no convenience method for.
///
/// End to end on purpose: the listener, the NIO parser, the daemon's
/// own `FileOperations` and a real directory. A WebDAV server tested against a
/// mocked filesystem would prove that the XML is well-formed and nothing about
/// whether it moved the right file.
final class Harness {
    let scratch = Scratch()
    /// A stand-in for `WebUI/dist`: the server serves whatever is here, and
    /// the tests need no node toolchain to prove that.
    let web = Scratch()
    let server: WebDAVServer
    let port: UInt16
    let user = "fila"
    let password = "s3cret"

    private let session = URLSession(configuration: .ephemeral)

    init(
        service: RemoteFileService = LocalService(),
        ioTimeout: TimeAmount = .seconds(HTTPConnection.readTimeoutSeconds),
        webRoot: String? = nil
    ) async throws {
        web.file("index.html", contents: "<!doctype html><script src=\"/_fila/app.js\"></script>")
        web.file("app.js", contents: "console.log('fila')")
        web.file(".secret.js", contents: "hidden")
        server = WebDAVServer(service: service, ioTimeout: ioTimeout)
        try server.start(.init(
            port: 0,
            username: user,
            password: password,
            root: scratch.root,
            advertisesBonjour: false,
            webRoot: URL(fileURLWithPath: webRoot ?? web.root, isDirectory: true)
        ))
        var found: UInt16?
        for _ in 0 ..< 100 {
            if case let .running(port) = server.status {
                found = port
                break
            }
            if case let .failed(reason) = server.status { throw HarnessFailure.listener(reason) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let found else { throw HarnessFailure.listener("never became ready") }
        port = found
    }

    deinit { server.stop() }

    enum HarnessFailure: Error {
        case listener(String)
        case badURL
    }

    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data

        var text: String { String(decoding: body, as: UTF8.self) }
        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    /// Preserve the target's percent encoding, keeping its query separate
    /// from the path so thumbnail requests do not violate Foundation's setter.
    func send(
        _ method: String,
        _ target: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        authorized: Bool = true
    ) async throws -> Reply {
        guard var components = URLComponents(string: "http://127.0.0.1:\(port)"),
              let requestTarget = URLComponents(string: target),
              requestTarget.scheme == nil, requestTarget.host == nil,
              requestTarget.fragment == nil, requestTarget.path.hasPrefix("/") else {
            throw HarnessFailure.badURL
        }
        components.percentEncodedPath = requestTarget.percentEncodedPath
        components.percentEncodedQuery = requestTarget.percentEncodedQuery
        guard let url = components.url else { throw HarnessFailure.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if authorized {
            let credentials = Data("\(user):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        var fields: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            fields[name.lowercased()] = value
        }
        return Reply(status: http.statusCode, headers: fields, body: data)
    }
}

/// Progress arrives on `URLSession`'s queue; this is somewhere to put it that
/// the test can read afterwards.
final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []

    func note(_ received: Int64) {
        lock.lock()
        values.append(received)
        lock.unlock()
    }

    var last: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }

    var all: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite("WebDAV over a real socket", .serialized)
struct ServerTests {
    @Test("Long backend jobs do not consume the socket idle timeout")
    func longBackendJob() async throws {
        let harness = try await Harness(service: LocalService(jobDelayNanoseconds: 600_000_000), ioTimeout: .milliseconds(250))
        harness.scratch.file("original.txt", contents: "complete")
        let reply = try await harness.send("COPY", "/original.txt", headers: ["Destination": "http://127.0.0.1:\(harness.port)/copy.txt", "Overwrite": "F"])
        #expect(reply.status == 201)
        #expect(harness.scratch.contents("original.txt") == "complete")
        #expect(harness.scratch.contents("copy.txt") == "complete")
    }

    @Test("Cancelled startup callbacks cannot stop a later sharing session", arguments: [UInt64(0), 1_000_000, 10_000_000])
    func restartDuringStartup(delay: UInt64) async throws {
        let scratch = Scratch()
        let server = WebDAVServer(service: LocalService())
        defer { server.stop() }
        let config = WebDAVServer.Configuration(port: 0, username: "fila", password: "test", root: scratch.root, advertisesBonjour: false)
        for _ in 0 ..< 5 {
            try server.start(config)
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            server.stop()
            #expect(server.status == .stopped)
        }
        try server.start(config)
        for _ in 0 ..< 100 {
            if server.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(server.isRunning)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(server.isRunning)
    }

    @Test("Refuses everything without credentials, and says how to send them")
    func requiresAuthentication() async throws {
        let harness = try await Harness()
        let reply = try await harness.send("OPTIONS", "/", authorized: false)
        #expect(reply.status == 401)
        // Digest first, Basic behind it. `URLSession` folds repeated headers
        // into one comma-joined value, so both spellings are in this string.
        let challenge = reply.header("www-authenticate") ?? ""
        #expect(challenge.contains("Digest"))
        #expect(challenge.contains("Basic"))
    }

    @Test("OPTIONS does not advertise unsupported locking")
    func options() async throws {
        let harness = try await Harness()
        let reply = try await harness.send("OPTIONS", "/")
        #expect(reply.status == 200)
        #expect(reply.header("dav") == "1")
        #expect(reply.header("allow")?.contains("LOCK") == false)
        #expect(reply.header("allow")?.contains("PROPFIND") == true)
        #expect(reply.header("ms-author-via") == "DAV")
    }

    @Test("PROPFIND lists a directory at depth 1 and only itself at depth 0")
    func propfind() async throws {
        let harness = try await Harness()
        harness.scratch.file("readme.txt", contents: "hello")
        harness.scratch.directory("folder")

        let deep = try await harness.send("PROPFIND", "/", headers: ["Depth": "1"])
        #expect(deep.status == 207)
        #expect(deep.text.contains("readme.txt"))
        #expect(deep.text.contains("<D:collection/>"))
        #expect(deep.text.contains("<D:getcontentlength>5</D:getcontentlength>"))

        let shallow = try await harness.send("PROPFIND", "/", headers: ["Depth": "0"])
        #expect(shallow.status == 207)
        #expect(!shallow.text.contains("readme.txt"))

        // A whole-device walk in one document is refused with the error that
        // tells the client to come back a level at a time.
        let infinite = try await harness.send("PROPFIND", "/", headers: ["Depth": "infinity"])
        #expect(infinite.status == 403)
        #expect(infinite.text.contains("propfind-finite-depth"))

        let missing = try await harness.send("PROPFIND", "/nope", headers: ["Depth": "0"])
        #expect(missing.status == 404)
    }

    @Test("A name with markup and spaces survives the listing and the fetch")
    func awkwardNames() async throws {
        let harness = try await Harness()
        harness.scratch.file("a & b <c>.txt", contents: "awkward")

        let listing = try await harness.send("PROPFIND", "/", headers: ["Depth": "1"])
        #expect(listing.text.contains("a &amp; b &lt;c&gt;.txt"))
        #expect(listing.text.contains("/a%20%26%20b%20%3Cc%3E.txt"))

        let fetched = try await harness.send("GET", "/a%20%26%20b%20%3Cc%3E.txt")
        #expect(fetched.text == "awkward")
    }

    @Test("GET streams a file, and a Range gets exactly that window")
    func get() async throws {
        let harness = try await Harness()
        harness.scratch.file("data.bin", contents: "0123456789")

        let whole = try await harness.send("GET", "/data.bin")
        #expect(whole.status == 200)
        #expect(whole.text == "0123456789")
        #expect(whole.header("accept-ranges") == "bytes")
        let tag = try #require(whole.header("etag"))
        #expect(tag.hasPrefix("W/\""))
        let metadata = try await harness.send("PROPFIND", "/data.bin", headers: ["Depth": "0"])
        #expect(metadata.text.contains("<D:getetag>\(tag)</D:getetag>"))

        let part = try await harness.send("GET", "/data.bin", headers: ["Range": "bytes=2-5"])
        #expect(part.status == 206)
        #expect(part.text == "2345")
        #expect(part.header("content-range") == "bytes 2-5/10")

        let past = try await harness.send("GET", "/data.bin", headers: ["Range": "bytes=99-"])
        #expect(past.status == 416)

        // A weak validator cannot establish that a partial response belongs
        // to the representation already held by a download client.
        for validator in [tag, "\"earlier-version\""] {
            let resumed = try await harness.send("GET", "/data.bin", headers: ["Range": "bytes=2-5", "If-Range": validator])
            #expect(resumed.status == 200)
            #expect(resumed.text == whole.text)
            #expect(resumed.header("content-range") == nil)
        }
    }

    @Test("Unsupported conditional mutations preserve the original file")
    func conditionalMutations() async throws {
        let harness = try await Harness()
        harness.scratch.file("keep.txt", contents: "original")
        for method in ["PUT", "DELETE", "MOVE", "COPY"] {
            let reply = try await harness.send(method, "/keep.txt", headers: [
                "If-Match": "\"prior-version\"", "Destination": "/changed.txt",
            ], body: method == "PUT" ? Data("replacement".utf8) : nil)
            #expect(reply.status == 501)
            #expect(try String(contentsOfFile: harness.scratch.path("keep.txt"), encoding: .utf8) == "original")
            #expect(!harness.scratch.exists("changed.txt"))
        }
        let dated = try await harness.send("PUT", "/keep.txt", headers: ["If-Unmodified-Since": "Thu, 01 Jan 1970 00:00:00 GMT"], body: Data("replacement".utf8))
        #expect(dated.status == 501)
        #expect(try String(contentsOfFile: harness.scratch.path("keep.txt"), encoding: .utf8) == "original")
    }

    @Test("A big file comes back byte for byte")
    func largeFile() async throws {
        let harness = try await Harness()
        // Over the 256 KB read window, so the streaming loop actually loops.
        let contents = String(repeating: "fila-", count: 200_000)
        harness.scratch.file("big.txt", contents: contents)

        let reply = try await harness.send("GET", "/big.txt")
        #expect(reply.status == 200)
        #expect(reply.body.count == contents.utf8.count)
        #expect(reply.text == contents)
    }

    /// A body after a HEAD is not a cosmetic error: the client does not read
    /// it, so it stays in the socket and is parsed as the start of the next
    /// reply. Two requests on one connection is what proves it is gone.
    @Test("HEAD sends no body, and the connection stays usable after it")
    func headSendsNoBody() async throws {
        let harness = try await Harness()
        harness.scratch.file("one.txt", contents: "body")

        for target in ["/", "/one.txt"] {
            let head = try await harness.send("HEAD", target)
            #expect(head.status == 200)
            #expect(head.body.isEmpty)
            // Whatever HEAD left behind would be read as this reply's status.
            let next = try await harness.send("GET", "/one.txt")
            #expect(next.status == 200)
            #expect(next.text == "body")
        }
    }

    @Test("A name with a control character does not take the listing down with it")
    func controlCharactersInNames() async throws {
        let harness = try await Harness()
        harness.scratch.file("bell\u{01}name.txt", contents: "x")
        harness.scratch.file("ordinary.txt", contents: "y")

        let listing = try await harness.send("PROPFIND", "/", headers: ["Depth": "1"])
        #expect(listing.status == 207)
        // The parse is the assertion: a raw 0x01 makes the whole document
        // ill-formed, and a client that cannot parse it shows an empty folder.
        _ = try XMLDocument(data: listing.body, options: [])
        #expect(listing.text.contains("ordinary.txt"))
    }

    @Test("GET on a directory is a page a browser can use")
    func directoryIndex() async throws {
        let harness = try await Harness()
        harness.scratch.file("one.txt")
        harness.scratch.directory("two")

        let reply = try await harness.send("GET", "/")
        #expect(reply.status == 200)
        #expect(reply.header("content-type")?.contains("text/html") == true)
        #expect(reply.text.contains("<!doctype html>"))
        #expect(reply.header("content-security-policy")?.contains("frame-ancestors 'none'") == true)
        #expect(reply.header("content-security-policy")?.contains("unsafe-inline") == false)
    }

    @Test("Frontend assets come from the web root and nothing else does")
    func frontendAssets() async throws {
        let harness = try await Harness()
        harness.scratch.directory("_fila")
        harness.scratch.file("_fila/shared.txt", contents: "the user's file")

        let script = try await harness.send("GET", "/_fila/app.js")
        #expect(script.status == 200)
        #expect(script.header("content-type")?.contains("text/javascript") == true)
        #expect(script.text == "console.log('fila')")
        #expect(script.header("content-disposition") == nil)

        let head = try await harness.send("HEAD", "/_fila/app.js")
        #expect(head.status == 200)
        #expect(head.header("content-length") == "\(script.body.count)")

        // Hidden, missing, wrong type, or not a plain name: never a file from the web root.
        for target in ["/_fila/.secret.js", "/_fila/missing.js", "/_fila/index.html", "/_fila/..%2Findex.html", "/_fila/a/b.js"] {
            let reply = try await harness.send("GET", target)
            #expect(reply.status != 200, "\(target)")
            #expect(!reply.text.contains("fila"), "\(target)")
        }

        // The prefix is reserved for GET only; the share's own `_fila` is still there for DAV.
        let listing = try await harness.send("PROPFIND", "/_fila/", headers: ["Depth": "1"])
        #expect(listing.status == 207)
        #expect(listing.text.contains("shared.txt"))
        let deleted = try await harness.send("DELETE", "/_fila/shared.txt")
        #expect(deleted.status == 204)
        #expect(!harness.scratch.exists("_fila/shared.txt"))
    }

    @Test("A thumbnail is a PNG of a file, and only of a file")
    func thumbnails() async throws {
        let harness = try await Harness()
        // A 1×1 red PNG.
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="))
        harness.scratch.file("dot.png", contents: String(decoding: [], as: UTF8.self))
        try png.write(to: URL(fileURLWithPath: harness.scratch.path("dot.png")))
        harness.scratch.directory("two")

        // QuickLook needs a rendering context the harness may not have (CI);
        // a refusal is acceptable, a wrong answer is not.
        let reply = try await harness.send("GET", "/dot.png?thumbnail=32")
        #expect(reply.status == 200 || reply.status == 404)
        if reply.status == 200 {
            #expect(reply.header("content-type") == "image/png")
            #expect(reply.body.starts(with: [0x89, 0x50, 0x4E, 0x47]))
            #expect(reply.header("content-disposition") == nil)
        }
        #expect(WebDAVHandler.thumbnailSide(in: "/a.png?thumbnail=9999") == 512)
        #expect(WebDAVHandler.thumbnailSide(in: "/a.png?x=1&thumbnail=") == 64)
        #expect(WebDAVHandler.thumbnailSide(in: "/a.png?thumb=1") == nil)

        // The query never changes what a directory or a missing file answers.
        let directory = try await harness.send("GET", "/two/?thumbnail=32")
        #expect(directory.status == 200)
        #expect(directory.header("content-type")?.contains("text/html") == true)
        let missing = try await harness.send("GET", "/missing.png?thumbnail=32")
        #expect(missing.status == 404)
        // And a plain GET of the file is still the file, not a thumbnail.
        let whole = try await harness.send("GET", "/dot.png")
        #expect(whole.body == png)
    }

    @Test("Without a web root the DAV protocol is intact and the page is absent")
    func noWebRoot() async throws {
        let server = WebDAVServer(service: LocalService())
        let scratch = Scratch()
        try server.start(.init(port: 0, username: "fila", password: "s3cret", root: scratch.root, advertisesBonjour: false))
        defer { server.stop() }
        var port: UInt16?
        for _ in 0 ..< 100 {
            if case let .running(found) = server.status { port = found; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let port_ = try #require(port)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port_)/")!)
        request.setValue("Basic \(Data("fila:s3cret".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        let (_, dav) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((dav as? HTTPURLResponse)?.statusCode == 207)
    }

    @Test("A Continue handshake completes a streamed upload")
    func continueUpload() async throws {
        let harness = try await Harness()
        let reply = try await harness.send("PUT", "/continue.txt", headers: ["Expect": "100-continue"], body: Data("complete".utf8))
        #expect(reply.status == 201)
        #expect(harness.scratch.contents("continue.txt") == "complete")
    }

    @Test("Concurrent browser uploads publish exactly one complete file")
    func exclusiveUploads() async throws {
        let harness = try await Harness()
        let left = Data(repeating: 65, count: 2 * 1_024 * 1_024)
        let right = Data(repeating: 66, count: 2 * 1_024 * 1_024)
        async let first = harness.send("PUT", "/race.bin", headers: ["If-None-Match": "*"], body: left)
        async let second = harness.send("PUT", "/race.bin", headers: ["If-None-Match": "*"], body: right)
        let replies = try await [first, second]
        #expect(replies.map(\.status).sorted() == [201, 412])
        let saved = try Data(contentsOf: URL(fileURLWithPath: harness.scratch.path("race.bin")))
        #expect(saved == left || saved == right)
        let names = try FileManager.default.contentsOfDirectory(atPath: harness.scratch.root)
        #expect(names == ["race.bin"])
    }

    @Test("Browser writes require the listener origin and existing uploads survive")
    func browserOriginAndCollision() async throws {
        let harness = try await Harness()
        harness.scratch.file("keep.txt", contents: "original")
        let rejected = try await harness.send("PUT", "/keep.txt", headers: ["Origin": "http://other.example"], body: Data("changed".utf8))
        #expect(rejected.status == 403)
        let collision = try await harness.send("PUT", "/keep.txt", headers: ["Origin": "http://127.0.0.1:\(harness.port)", "If-None-Match": "*"], body: Data("changed".utf8))
        #expect(collision.status == 412)
        #expect(harness.scratch.contents("keep.txt") == "original")
        let created = try await harness.send("PUT", "/new.txt", headers: ["Origin": "http://127.0.0.1:\(harness.port)", "If-None-Match": "*"], body: Data("new".utf8))
        #expect(created.status == 201)
        let opaque = try await harness.send("DELETE", "/keep.txt", headers: ["Origin": "null"])
        #expect(opaque.status == 403)
        #expect(harness.scratch.exists("keep.txt"))
    }

    @Test("A named pipe is refused without opening a blocking file stream")
    func refusesSpecialFiles() async throws {
        let harness = try await Harness()
        #expect(mkfifo(harness.scratch.path("pipe"), 0o600) == 0)
        let reply = try await harness.send("GET", "/pipe")
        #expect(reply.status == 403)
    }

    @Test("Shared HTML downloads without executing as the authenticated web application")
    func sharedHTMLIsAttachment() async throws {
        let harness = try await Harness()
        harness.scratch.file("page.html", contents: "<script>document.title='file'</script>")
        let reply = try await harness.send("GET", "/page.html")
        #expect(reply.status == 200)
        #expect(reply.header("content-disposition") == "attachment")
        #expect(reply.header("content-security-policy")?.contains("sandbox") == true)
        #expect(reply.header("x-content-type-options") == "nosniff")
    }

    @Test("PUT creates, then replaces, and the bytes land on disk")
    func put() async throws {
        let harness = try await Harness()

        let created = try await harness.send("PUT", "/note.txt", body: Data("first".utf8))
        #expect(created.status == 201)
        #expect(harness.scratch.contents("note.txt") == "first")

        // A new file keeps the temporary's mode, so the temporary's mode has to
        // be one the user can read the file back with.
        var found = stat()
        #expect(lstat(harness.scratch.path("note.txt"), &found) == 0)
        #expect(found.st_mode & 0o777 == 0o644)

        let replaced = try await harness.send("PUT", "/note.txt", body: Data("second".utf8))
        #expect(replaced.status == 204)
        #expect(harness.scratch.contents("note.txt") == "second")

        // Into a directory that does not exist. Nothing is invented for it.
        let orphan = try await harness.send("PUT", "/missing/note.txt", body: Data("x".utf8))
        #expect(orphan.status == 409)
        #expect(!harness.scratch.exists("missing"))
    }

    @Test("PUT leaves no temporary behind when it fails")
    func putCleansUp() async throws {
        let harness = try await Harness()
        harness.scratch.directory("folder")

        // A PUT onto a directory is a 405, and the temporary must not survive it.
        let refused = try await harness.send("PUT", "/folder", body: Data("x".utf8))
        #expect(refused.status == 405)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: harness.scratch.root)
        #expect(!leftovers.contains { $0.hasPrefix(".fila-tmp-") })
    }

    @Test("MKCOL makes one directory and refuses to make two")
    func mkcol() async throws {
        let harness = try await Harness()

        let made = try await harness.send("MKCOL", "/folder")
        #expect(made.status == 201)
        #expect(harness.scratch.exists("folder"))

        let again = try await harness.send("MKCOL", "/folder")
        #expect(again.status == 405)

        let orphan = try await harness.send("MKCOL", "/a/b")
        #expect(orphan.status == 409)
    }

    @Test("MOVE renames, and honours Overwrite: F")
    func move() async throws {
        let harness = try await Harness()
        harness.scratch.file("from.txt", contents: "moved")
        harness.scratch.file("blocker.txt", contents: "keep")

        let moved = try await harness.send("MOVE", "/from.txt", headers: [
            "Destination": "http://127.0.0.1:\(harness.port)/to.txt",
        ])
        #expect(moved.status == 201)
        #expect(harness.scratch.contents("to.txt") == "moved")
        #expect(!harness.scratch.exists("from.txt"))

        let refused = try await harness.send("MOVE", "/to.txt", headers: [
            "Destination": "http://127.0.0.1:\(harness.port)/blocker.txt",
            "Overwrite": "F",
        ])
        #expect(refused.status == 412)
        #expect(harness.scratch.contents("blocker.txt") == "keep")

        let replaced = try await harness.send("MOVE", "/to.txt", headers: [
            "Destination": "http://127.0.0.1:\(harness.port)/blocker.txt",
        ])
        #expect(replaced.status == 204)
        #expect(harness.scratch.contents("blocker.txt") == "moved")
    }

    @Test("COPY duplicates under a new name and leaves no staging directory")
    func copy() async throws {
        let harness = try await Harness()
        harness.scratch.file("original.txt", contents: "copy me")

        let copied = try await harness.send("COPY", "/original.txt", headers: [
            "Destination": "http://127.0.0.1:\(harness.port)/duplicate.txt",
        ])
        #expect(copied.status == 201)
        #expect(harness.scratch.contents("original.txt") == "copy me")
        #expect(harness.scratch.contents("duplicate.txt") == "copy me")

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: harness.scratch.root)
        #expect(!leftovers.contains { $0.hasPrefix(".fila-dav-") })
    }

    @Test("COPY of a directory takes the tree with it")
    func copyTree() async throws {
        let harness = try await Harness()
        harness.scratch.directory("tree")
        harness.scratch.file("tree/leaf.txt", contents: "leaf")

        let copied = try await harness.send("COPY", "/tree", headers: [
            "Destination": "http://127.0.0.1:\(harness.port)/tree-copy",
            "Depth": "infinity",
        ])
        #expect(copied.status == 201)
        #expect(harness.scratch.contents("tree-copy/leaf.txt") == "leaf")
    }

    @Test("DELETE removes a tree, and never the served root")
    func delete() async throws {
        let harness = try await Harness()
        harness.scratch.directory("tree")
        harness.scratch.file("tree/leaf.txt")

        let removed = try await harness.send("DELETE", "/tree")
        #expect(removed.status == 204)
        #expect(!harness.scratch.exists("tree"))

        let missing = try await harness.send("DELETE", "/tree")
        #expect(missing.status == 404)

        let root = try await harness.send("DELETE", "/")
        #expect(root.status == 403)
        #expect(harness.scratch.exists(""))
    }

    @Test("DELETE accepts encoded folder names and collection trailing slashes", arguments: ["未命名文件夹", "100% #? 😀", "%E6%9C%AA"])
    func deleteEncodedFolder(name: String) async throws {
        let harness = try await Harness()
        let container = ".Trash/BA394090-7848-4AC2-B6C1-F8035B8120BF"
        harness.scratch.directory(".Trash")
        harness.scratch.directory(container)
        let relative = container + "/" + name
        let path = harness.scratch.directory(relative)
        harness.scratch.file(relative + "/内容.txt", contents: "remove")
        harness.scratch.file(container + "/保留.txt", contents: "keep")
        let target = RemotePath.href(for: path, root: harness.scratch.root, isCollection: true)

        let listing = try await harness.send("PROPFIND", "/" + container + "/", headers: ["Depth": "1"])
        #expect(listing.status == 207)
        #expect(listing.text.contains("<D:href>" + target + "</D:href>"))
        let removed = try await harness.send("DELETE", target)
        #expect(removed.status == 204)
        #expect(!harness.scratch.exists(relative))
        #expect(harness.scratch.contents(container + "/保留.txt") == "keep")
    }

    @Test("DELETE is permanent even when the backend trash is unavailable")
    func deleteWithoutTrash() async throws {
        let bootstrap = Scratch()
        bootstrap.file(FilaTrash.directoryName, contents: "unavailable")
        let harness = try await Harness(service: LocalService(bootstrapRoot: bootstrap.root))
        harness.scratch.directory("tree")
        harness.scratch.file("tree/leaf.txt")

        let removed = try await harness.send("DELETE", "/tree/")
        #expect(removed.status == 204)
        #expect(!harness.scratch.exists("tree"))
        #expect(bootstrap.contents(FilaTrash.directoryName) == "unavailable")
    }

    @Test("Lock-dependent clients receive an explicit refusal")
    func locking() async throws {
        let harness = try await Harness()
        harness.scratch.file("locked.txt", contents: "original")
        for method in ["LOCK", "UNLOCK"] {
            let reply = try await harness.send(method, "/locked.txt")
            #expect(reply.status == 405)
            #expect(reply.header("lock-token") == nil)
        }
        let properties = try await harness.send("PROPFIND", "/locked.txt", headers: ["Depth": "0"])
        #expect(properties.text.contains("<D:supportedlock/>"))
        #expect(!properties.text.contains("<D:lockentry>"))
        for method in ["PUT", "DELETE", "MOVE", "COPY"] {
            let reply = try await harness.send(method, "/locked.txt", headers: [
                "If": "(<opaquelocktoken:prior-session>)", "Destination": "/changed.txt",
            ], body: method == "PUT" ? Data("replacement".utf8) : nil)
            #expect(reply.status == 501)
            #expect(harness.scratch.contents("locked.txt") == "original")
            #expect(!harness.scratch.exists("changed.txt"))
        }
    }

    @Test("An escaped traversal is refused at the door")
    func refusesTraversal() async throws {
        let harness = try await Harness()
        // Percent-encoded so that neither `URL` nor `URLSession` tidies it away
        // before it reaches the server — which is the whole point of the check.
        let escaped = try await harness.send("GET", "/%2e%2e/%2e%2e/etc/passwd")
        #expect(escaped.status == 400)

        let encodedSeparator = try await harness.send("GET", "/a%2Fb")
        #expect(encodedSeparator.status == 400)
    }

    @Test("A symlink pointing out of the served root is refused")
    func refusesSymlinkEscape() async throws {
        let harness = try await Harness()
        // Nothing lexical can catch this: the target has no `..` in it and no
        // separator that was hidden. Only the canonical path the daemon reports
        // says where it actually lands.
        #expect(symlink("/private/etc", harness.scratch.path("escape")) == 0)

        #expect(try await harness.send("GET", "/escape/hosts").status == 403)
        #expect(try await harness.send("PROPFIND", "/escape", headers: ["Depth": "1"]).status == 403)
        #expect(try await harness.send("PUT", "/escape/planted", body: Data("x".utf8)).status == 403)
        #expect(!FileManager.default.fileExists(atPath: "/private/etc/planted"))
    }

    @Test("An unknown verb is refused with the list of the ones that work")
    func unknownMethod() async throws {
        let harness = try await Harness()
        let reply = try await harness.send("PATCH", "/", body: Data("x".utf8))
        #expect(reply.status == 405)
        #expect(reply.header("allow")?.contains("MKCOL") == true)
    }

    /// The download's HTTP half, against this package's own server so there is
    /// a real socket and a real body on the other end. Placing the result on a
    /// root-owned path is the app's half and needs the daemon, so it is not
    /// here — see `OperationCenter.download`.
    @Test("A download lands the bytes, reports progress, and refuses a 404 page")
    func downloading() async throws {
        let harness = try await Harness()
        let contents = String(repeating: "payload-", count: 100_000)
        harness.scratch.file("payload.bin", contents: contents)

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("fila-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let source = URL(string: "http://fila:s3cret@127.0.0.1:\(harness.port)/payload.bin")!
        let reported = Reports()
        let file = try await URLDownload.fetch(source, into: staging) { reported.note($0.received) }
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == contents)
        // The last report is the whole file: a bar that stops at 90% and then
        // the row says "done" is the shape this assertion exists to prevent.
        #expect(reported.last == Int64(contents.utf8.count), "reports: \(reported.all)")

        // A server that answers with something other than the file must not
        // leave that something looking like the file.
        let missing = URL(string: "http://fila:s3cret@127.0.0.1:\(harness.port)/not-here.bin")!
        await #expect(throws: URLDownload.Failure.httpStatus(404)) {
            try await URLDownload.fetch(missing, into: staging) { _ in }
        }
    }

    @Test("A download's name comes from the URL, and cannot be a path")
    func downloadNames() {
        #expect(URLDownload.suggestedName(for: URL(string: "http://x/a/b.zip")!) == "b.zip")
        #expect(URLDownload.suggestedName(for: URL(string: "http://x/")!) == "download")
        #expect(URLDownload.suggestedName(for: URL(string: "http://x")!) == "download")
        // A traversal collapses into one ordinary name rather than a path.
        #expect(URLDownload.sanitize("../../etc/passwd") == ".._.._etc_passwd")
        #expect(URLDownload.sanitize("..") == nil)
        #expect(URLDownload.sanitize("/") == nil)
        #expect(URLDownload.sanitize("  ") == nil)
    }

    @Test("Connections and their verdicts reach the log the user reads")
    func logsConnections() async throws {
        let harness = try await Harness()
        _ = try await harness.send("OPTIONS", "/")
        // The client can receive the response before the server resumes to log it.
        for _ in 0 ..< 100 {
            if harness.server.log.contains(where: { $0.text.contains("OPTIONS / → 200") }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let lines = harness.server.log.map(\.text)
        #expect(lines.contains { $0.contains("Sharing started on port ") })
        #expect(lines.contains { $0.contains("connected") })
        #expect(lines.contains { $0.contains("OPTIONS / → 200") })
    }
}
