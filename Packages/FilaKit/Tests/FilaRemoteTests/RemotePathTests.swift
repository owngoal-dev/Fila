import Foundation
import Testing
import NIOCore
import NIOHTTP1
import NIOEmbedded

@testable import FilaRemote

// The request target is written by whoever reached the port. Everything here is
// about what happens to it before it becomes a path.

@Suite("Request targets")
struct RemotePathTests {
    @Test("Decodes after splitting, so an escaped separator stays inside a name")
    func decodesPerComponent() {
        #expect(RemotePath.components(of: "/a/b%20c") == ["a", "b c"])
        // The whole reason to split first: decoded as one string this is
        // `/a/../etc` and hands back the parent.
        #expect(RemotePath.components(of: "/a/%2e%2e/etc") == nil)
        #expect(RemotePath.components(of: "/a/b%2Fc") == nil)
    }

    @Test("Refuses anything that could climb out")
    func refusesTraversal() {
        #expect(RemotePath.components(of: "/../etc") == nil)
        #expect(RemotePath.components(of: "/a/../../etc") == nil)
        #expect(RemotePath.components(of: "/a/./b") == nil)
        #expect(RemotePath.components(of: "/a/%00b") == nil)
        #expect(RemotePath.components(of: "relative/path") == nil)
    }

    @Test("Stays under the served root")
    func staysUnderRoot() {
        #expect(RemotePath.filesystemPath(for: "/", root: "/private/tmp/x") == "/private/tmp/x")
        #expect(RemotePath.filesystemPath(for: "/a/b", root: "/private/tmp/x") == "/private/tmp/x/a/b")
        #expect(RemotePath.filesystemPath(for: "/a/b", root: "/") == "/a/b")
        #expect(RemotePath.filesystemPath(for: "/../a", root: "/private/tmp/x") == nil)
    }

    @Test("Takes the path out of the absolute form a Destination header uses")
    func absoluteForm() {
        #expect(RemotePath.filesystemPath(for: "http://phone.local:8080/a/b", root: "/") == "/a/b")
        #expect(RemotePath.filesystemPath(for: "http://phone.local:8080", root: "/") == "/")
        #expect(RemotePath.filesystemPath(for: "http://phone.local/a?v=1", root: "/") == "/a")
    }

    @Test("Encodes an href a component at a time, separators included")
    func encodesHref() {
        #expect(RemotePath.href(for: "/a/b c", root: "/", isCollection: false) == "/a/b%20c")
        #expect(RemotePath.href(for: "/a/b", root: "/", isCollection: true) == "/a/b/")
        #expect(RemotePath.href(for: "/", root: "/", isCollection: true) == "/")
        #expect(RemotePath.href(for: "/tmp/x/a", root: "/tmp/x", isCollection: false) == "/a")
        #expect(RemotePath.escape("a&b?c#d") == "a%26b%3Fc%23d")
    }
}

@Suite("HTTP framing")
struct HTTPMessageTests {
    @Test("Header names are case-insensitive, values keep their spelling")
    func parsesHeaders() {
        let block = "PROPFIND /a HTTP/1.1\r\nHost: x\r\nDepth: 1\r\nCONTENT-LENGTH: 12\r\n"
        let request = HTTPRequest.parse(Data(block.utf8))
        #expect(request?.method == "PROPFIND")
        #expect(request?.target == "/a")
        #expect(request?.depth == "1")
        #expect(request?.contentLength == 12)
        #expect(request?.wantsKeepAlive == true)
    }

    @Test("An absent Depth means infinity, which is the one PROPFIND refuses")
    func depthDefaultsToInfinity() {
        let request = HTTPRequest.parse(Data("PROPFIND / HTTP/1.1\r\nHost: x\r\n".utf8))
        #expect(request?.depth == "infinity")
    }

    @Test("Overwrite is only false when it says F")
    func overwriteDefault() {
        #expect(HTTPRequest.parse(Data("MOVE /a HTTP/1.1\r\nOverwrite: F\r\n".utf8))?.allowsOverwrite == false)
        #expect(HTTPRequest.parse(Data("MOVE /a HTTP/1.1\r\nOverwrite: T\r\n".utf8))?.allowsOverwrite == true)
        #expect(HTTPRequest.parse(Data("MOVE /a HTTP/1.1\r\nHost: x\r\n".utf8))?.allowsOverwrite == true)
    }

    @Test("Ranges, in the three forms a client sends")
    func parsesRanges() {
        func range(_ text: String?, size: Int64 = 100) -> ByteRange.Parsed {
            ByteRange.parse(text, fileSize: size)
        }
        if case let .range(value) = range("bytes=0-9") {
            #expect(value.offset == 0 && value.count == 10)
        } else {
            Issue.record("bytes=0-9 should parse")
        }
        if case let .range(value) = range("bytes=90-") {
            #expect(value.offset == 90 && value.count == 10)
        } else {
            Issue.record("bytes=90- should parse")
        }
        if case let .range(value) = range("bytes=-10") {
            #expect(value.offset == 90 && value.count == 10)
        } else {
            Issue.record("bytes=-10 should parse")
        }
        // Past the end is a 416, not a whole file.
        if case .unsatisfiable = range("bytes=200-") {} else { Issue.record("bytes=200- is unsatisfiable") }
        // Clamped rather than refused: asking for more than there is is legal.
        if case let .range(value) = range("bytes=95-200") {
            #expect(value.offset == 95 && value.count == 5)
        } else {
            Issue.record("bytes=95-200 should clamp")
        }
        if case .absent = range(nil) {} else { Issue.record("no header means no range") }
        if case .absent = range("bytes=0-9,20-29") {} else { Issue.record("multiple ranges fall back") }
    }
}

@Suite("Authentication")
struct AuthenticationTests {
    private let nonces = DigestNonces()

    /// Straight at the policy, with no server and no filesystem behind it: what
    /// is under test is whether a credential is accepted, and nothing about a
    /// connection changes that answer.
    private func accepts(
        _ authorization: String?,
        method: String = "GET",
        target: String = "/",
        user: String = "fila",
        password: String = "s3cret"
    ) -> Bool {
        HTTPAuthentication.isAuthorized(
            request(authorization, method: method, target: target),
            username: user,
            password: password,
            nonces: nonces
        )
    }

    private func request(_ authorization: String?, method: String = "GET", target: String = "/") -> HTTPRequest {
        var text = "\(method) \(target) HTTP/1.1\r\nHost: x\r\n"
        if let authorization { text += "Authorization: \(authorization)\r\n" }
        return HTTPRequest.parse(Data(text.utf8))!
    }

    /// What a client computes, so the test proves the server agrees with the
    /// specification rather than with itself.
    private func digest(
        user: String,
        password: String,
        method: String,
        uri: String,
        nonce: String,
        realm: String = HTTPAuthentication.realm
    ) -> String {
        let ha1 = HTTPAuthentication.md5("\(user):\(realm):\(password)")
        let ha2 = HTTPAuthentication.md5("\(method):\(uri)")
        let response = HTTPAuthentication.md5("\(ha1):\(nonce):00000001:abc123:auth:\(ha2)")
        return """
        Digest username="\(user)", realm="\(realm)", nonce="\(nonce)", uri="\(uri)", \
        qop=auth, nc=00000001, cnonce="abc123", response="\(response)", algorithm=MD5
        """
    }

    @Test("Only the right Basic credentials get in")
    func basic() {
        let good = Data("fila:s3cret".utf8).base64EncodedString()
        #expect(accepts("Basic \(good)"))
        #expect(accepts("basic \(good)"))
        #expect(!accepts(nil))
        #expect(!accepts("Basic \(Data("fila:wrong".utf8).base64EncodedString())"))
        #expect(!accepts("Basic \(Data("other:s3cret".utf8).base64EncodedString())"))
        #expect(!accepts("Basic not-base64!!"))
        // A password with a colon in it is one string, not two.
        #expect(accepts(
            "Basic \(Data("a:b:c".utf8).base64EncodedString())",
            user: "a",
            password: "b:c"
        ))
    }

    @Test("Digest is accepted, and is bound to the method and the path")
    func digestAuthentication() {
        let nonce = nonces.issue()

        #expect(accepts(digest(user: "fila", password: "s3cret", method: "GET", uri: "/", nonce: nonce)))
        #expect(!accepts(digest(user: "fila", password: "wrong", method: "GET", uri: "/", nonce: nonce)))
        // The digest of a GET replayed as a DELETE must not verify: the method
        // is inside the hash for exactly this reason.
        #expect(!accepts(
            digest(user: "fila", password: "s3cret", method: "GET", uri: "/", nonce: nonce),
            method: "DELETE"
        ))
        // A nonce we never issued is a nonce the client chose.
        #expect(!accepts(digest(user: "fila", password: "s3cret", method: "GET", uri: "/", nonce: "made-up")))
        // The credential is bound to the path in the request line, not just to
        // whatever path the client hashed. Without this comparison a captured
        // header would be valid against every path for the nonce's lifetime,
        // and the one holding it would choose the target.
        #expect(!accepts(
            digest(user: "fila", password: "s3cret", method: "GET", uri: "/", nonce: nonce),
            target: "/somewhere/else"
        ))
        #expect(accepts(
            digest(user: "fila", password: "s3cret", method: "GET", uri: "/a/b", nonce: nonce),
            target: "/a/b"
        ))
        // The same resource spelled the way macOS spells a Destination.
        #expect(accepts(
            digest(user: "fila", password: "s3cret", method: "GET", uri: "http://host:8080/a/b", nonce: nonce),
            target: "/a/b"
        ))
        // A target the server will refuse anyway still authenticates, so the
        // client is told 400 rather than being sent back to the password box.
        #expect(accepts(
            digest(user: "fila", password: "s3cret", method: "GET", uri: "/%2e%2e/etc", nonce: nonce),
            target: "/%2e%2e/etc"
        ))
        // A different realm gives a different HA1, and must not be accepted
        // just because the client said so.
        #expect(!accepts(
            digest(user: "fila", password: "s3cret", method: "GET", uri: "/", nonce: nonce, realm: "Other")
        ))
    }

    @Test("Header parsing keeps commas inside quoted values")
    func parsesDigestHeader() {
        let fields = HTTPAuthentication.parse(
            #"Digest username="a,b", realm="Fila", nc=00000001, response="deadbeef""#
        )
        #expect(fields["username"] == "a,b")
        #expect(fields["realm"] == "Fila")
        #expect(fields["nc"] == "00000001")
        #expect(fields["response"] == "deadbeef")
    }

    @Test("A 401 offers Digest before Basic, and offers nothing else")
    func challenges() {
        let offered = HTTPAuthentication.challenges(nonces: nonces)
        #expect(offered.count == 2)
        #expect(offered[0].hasPrefix("Digest "))
        #expect(offered[1].hasPrefix("Basic "))
        #expect(offered[0].contains("qop=\"auth\""))
    }

    @Test("A server with no password refuses to start")
    func passwordRequired() {
        let server = WebDAVServer(service: LocalService())
        #expect(throws: WebDAVServer.StartFailure.passwordRequired) {
            try server.start(.init(port: 0, username: "fila", password: "", advertisesBonjour: false))
        }
    }
}

@Suite("XML")
struct DAVXMLTests {
    @Test("A file named with markup does not break the listing")
    func escapes() {
        #expect(DAVXML.escape("a & b") == "a &amp; b")
        #expect(DAVXML.escape("<x>") == "&lt;x&gt;")
        #expect(DAVXML.escape("\"'") == "&quot;&apos;")
    }
}

// Exercise the production NIO parser synchronously on its creating thread.
private extension HTTPRequest {
    static func parse(_ block: Data) -> HTTPRequest? {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(HTTPRequestDecoder()))
        defer { _ = try? channel.finish() }
        do {
            _ = try channel.writeInbound(ByteBuffer(bytes: block + Data("\r\n".utf8)))
            while let part = try channel.readInbound(as: HTTPServerRequestPart.self) {
                if case let .head(head) = part { return HTTPRequest(head) }
            }
        } catch { return nil }
        return nil
    }
}
