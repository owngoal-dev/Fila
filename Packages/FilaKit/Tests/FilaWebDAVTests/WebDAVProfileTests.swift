import FilaBackendKit
@testable import FilaWebDAV
import Foundation
import Testing

@Suite("WebDAV profiles")
struct WebDAVProfileTests {
    @Test
    func `Identity follows the profile ID, not the address`() {
        let a = WebDAVProfile(name: "Alist", address: "http://NAS.local:5244/dav")
        var b = a
        b.name = "Renamed"
        b.username = "someone"
        #expect(a.backendID == b.backendID)
        #expect(a.credentialKey == b.credentialKey)
        #expect(a.namesSameServer(as: b))
        var c = a
        c.address = "http://nas.local:5244/dav/"
        #expect(a.namesSameServer(as: c), "host case and a trailing slash name the same folder")
        c.address = "http://nas.local:5244/dav/other"
        #expect(!a.namesSameServer(as: c))
        c.address = "https://nas.local:5244/dav"
        #expect(!a.namesSameServer(as: c))
        c.address = "http://nas.local/dav"
        #expect(!a.namesSameServer(as: c))
        var d = WebDAVProfile(name: "", address: "https://example.com/dav")
        d.address = "https://example.com:443/dav"
        #expect(d.namesSameServer(as: WebDAVProfile(name: "", address: "https://example.com/dav")), "the default port is the port")
    }

    @Test
    func `Validation names what is wrong with the address`() {
        #expect(WebDAVProfile(name: "", address: " ").validationFailure == .addressMissing)
        #expect(WebDAVProfile(name: "", address: "ftp://host/").validationFailure == .schemeUnsupported)
        #expect(WebDAVProfile(name: "", address: "host:5244/dav").validationFailure == .schemeUnsupported)
        #expect(WebDAVProfile(name: "", address: "http:///dav").validationFailure == .addressInvalid)
        #expect(WebDAVProfile(name: "", address: "http://user:pw@host/dav").validationFailure == .addressInvalid)
        #expect(WebDAVProfile(name: "", address: "http://host/dav?x=1").validationFailure == .addressInvalid)
        #expect(WebDAVProfile(name: "", address: "http://host:0/dav").validationFailure == .addressInvalid)
        #expect(WebDAVProfile(name: "", address: "HTTP://192.168.1.2:5244/dav").validationFailure == nil)
    }

    @Test
    func `The base URL is the folder, with its slash`() throws {
        let profile = WebDAVProfile(name: "", address: "HTTP://Host:5244/dav")
        #expect(try #require(profile.baseURL).absoluteString == "http://host:5244/dav/")
        #expect(try #require(WebDAVProfile(name: "", address: "https://host").baseURL).absoluteString == "https://host/")
        #expect(WebDAVProfile(name: "", address: "nope").baseURL == nil)
    }

    @Test
    func `Display name falls back to the host`() {
        #expect(WebDAVProfile(name: "  ", address: "http://nas.local:5244/dav").displayName == "nas.local")
        #expect(WebDAVProfile(name: "Cloud", address: "http://nas.local/dav").displayName == "Cloud")
    }

    @Test
    func `The profile list round-trips without the password`() throws {
        let list = WebDAVProfileList(profiles: [
            WebDAVProfile(name: "A", address: "http://a/dav", username: "u"),
            WebDAVProfile(name: "B", address: "https://b"),
        ])
        let data = try JSONEncoder().encode(list)
        #expect(!String(decoding: data, as: UTF8.self).lowercased().contains("password"))
        #expect(try JSONDecoder().decode(WebDAVProfileList.self, from: data) == list)
    }

    @Test
    @MainActor
    func `The store keeps the record and the password together`() throws {
        let defaults = try #require(UserDefaults(suiteName: "fila-webdav-tests-\(UUID().uuidString)"))
        let credentials = MemoryCredentialStore()
        let store = WebDAVProfileStore(
            storage: UserDefaultsStorage<WebDAVProfileList>(defaults: defaults, key: WebDAVProfileList.storageKey),
            credentials: credentials,
        )
        let profile = WebDAVProfile(name: "A", address: "http://a/dav", username: "u")
        try store.save(profile, password: "secret")
        #expect(try store.password(for: profile) == "secret")
        try store.save(profile)
        #expect(try store.password(for: profile) == "secret", "an edit that leaves the field alone keeps it")
        credentials.failure = CocoaError(.fileWriteNoPermission)
        var renamed = profile
        renamed.name = "B"
        #expect(throws: (any Error).self) { try store.save(renamed, password: "other") }
        #expect(store.profile(profile.id)?.name == "A", "a refused password puts the record back")
        credentials.failure = nil
        try store.remove(profile.id)
        #expect(store.profiles.isEmpty)
        #expect(try credentials.secret(for: profile.credentialKey) == nil)
    }
}

@Suite("WebDAV backend")
struct WebDAVBackendTests {
    @Test
    @MainActor
    func `A removed server refuses to open a new session`() async throws {
        let defaults = try #require(UserDefaults(suiteName: "fila-webdav-tests-\(UUID().uuidString)"))
        let profile = WebDAVProfile(name: "", address: "http://127.0.0.1:9/dav", username: "u")
        let backend = WebDAVBackend(
            profile: profile,
            storage: UserDefaultsStorage<FileBackendPreferences>(defaults: defaults, key: profile.preferencesKey),
            credentials: MemoryCredentialStore(),
        )
        _ = try await backend.fileService()
        backend.retire()
        await #expect(throws: WebDAVError.removed) {
            _ = try await backend.fileService()
        }
    }
}

@Suite("WebDAV wire")
struct WebDAVWireTests {
    private let transport = WebDAVTransport(baseURL: URL(string: "http://host:5244/dav/")!, username: nil, password: nil)

    @Test
    func `Every component is one name on the wire`() throws {
        #expect(transport.url(for: [], collection: true).absoluteString == "http://host:5244/dav/")
        #expect(transport.url(for: ["a", "b c"], collection: false).absoluteString == "http://host:5244/dav/a/b%20c")
        #expect(transport.url(for: ["a"], collection: true).absoluteString == "http://host:5244/dav/a/")
        #expect(transport.url(for: ["100%", "a?b#c;d"], collection: false).absoluteString == "http://host:5244/dav/100%25/a%3Fb%23c%3Bd")
        #expect(transport.url(for: ["文件"], collection: false).absoluteString == "http://host:5244/dav/%E6%96%87%E4%BB%B6")
        transport.close()
    }

    @Test
    func `A multistatus is read by namespace, and only successful properties count`() throws {
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <multistatus xmlns="DAV:" xmlns:x="urn:other">
          <response>
            <href>/dav/folder/</href>
            <propstat>
              <prop><resourcetype><collection/></resourcetype><getlastmodified>Tue, 15 Oct 2024 08:30:00 GMT</getlastmodified></prop>
              <status>HTTP/1.1 200 OK</status>
            </propstat>
            <propstat>
              <prop><getcontentlength>99</getcontentlength></prop>
              <status>HTTP/1.1 404 Not Found</status>
            </propstat>
          </response>
          <response>
            <href>http://host:5244/dav/folder/%E6%96%87%20a.txt</href>
            <propstat>
              <prop><resourcetype/><getcontentlength>12</getcontentlength><getetag>"abc"</getetag><x:collection/></prop>
              <status>HTTP/1.1 200 OK</status>
            </propstat>
          </response>
        </multistatus>
        """.utf8)
        let resources = try WebDAVMultistatus.parse(body)
        #expect(resources.count == 2)
        #expect(resources[0].isCollection)
        #expect(resources[0].contentLength == nil, "a 404 propstat contributes nothing")
        #expect(resources[0].lastModified == Date(timeIntervalSince1970: 1_728_981_000))
        #expect(resources[0].components == ["dav", "folder"])
        #expect(!resources[1].isCollection, "a collection element in another namespace is not DAV's")
        #expect(resources[1].contentLength == 12)
        #expect(resources[1].etag == "\"abc\"")
        #expect(resources[1].components == ["dav", "folder", "文 a.txt"])
    }

    @Test
    func `The folder is found under a proxy's prefix, and only direct children are listed`() {
        let resources = [
            WebDAVResource(href: "/dav/docs/", isCollection: true),
            WebDAVResource(href: "/dav/docs/a.txt"),
            WebDAVResource(href: "/dav/docs/sub/", isCollection: true),
            WebDAVResource(href: "/dav/docs/sub/deep.txt"),
            WebDAVResource(href: "/dav/docs/a%2Fb"),
        ]
        // Asked for at /alist/dav/docs/, answered as /dav/docs/.
        let split = WebDAVFileService.split(resources, requested: ["alist", "dav", "docs"])
        #expect(split.own?.href == "/dav/docs/")
        #expect(split.children.map(\.1) == ["a.txt", "sub", "a/b"])
        #expect(split.skipped == 1, "the entry two levels down is not a child")
    }

    @Test
    func `A lone response is the folder only when it carries the folder's name`() {
        let empty = WebDAVFileService.split(
            [WebDAVResource(href: "/dav/docs/", isCollection: true)], requested: ["alist", "dav", "docs"],
        )
        #expect(empty.own != nil, "an empty folder under another prefix")
        let childOnly = WebDAVFileService.split(
            [WebDAVResource(href: "/dav/docs/sub/", isCollection: true)], requested: ["alist", "dav", "docs"],
        )
        #expect(childOnly.own == nil, "a reply without the folder never makes its child the folder")
        #expect(childOnly.skipped == 1)
        let siblings = WebDAVFileService.split(
            [WebDAVResource(href: "/dav/a/"), WebDAVResource(href: "/dav/b/")], requested: ["x", "dav", "docs"],
        )
        #expect(siblings.own == nil, "no response that every other one sits under")
    }

    @Test
    func `The folder answered in NFD is still the folder`() {
        let nfd = "caf\u{0065}\u{0301}"
        let split = WebDAVFileService.split(
            [WebDAVResource(href: "/dav/" + nfd.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "/", isCollection: true)],
            requested: ["dav", "caf\u{00E9}"],
        )
        #expect(split.own != nil)
        #expect(split.children.isEmpty)
    }

    @Test
    func `An encoded slash stays inside its component`() {
        #expect(WebDAVResource(href: "/dav/a%2Fb/").components == ["dav", "a/b"])
        #expect(WebDAVResource(href: "https://h/dav/%E6%96%87").components == ["dav", "文"])
    }

    @Test
    func `A prefixed multistatus reads the same`() throws {
        let body = Data("""
        <D:multistatus xmlns:D="DAV:"><D:response><D:href>/a</D:href><D:propstat><D:prop>\
        <D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status>\
        </D:propstat></D:response></D:multistatus>
        """.utf8)
        let resources = try WebDAVMultistatus.parse(body)
        #expect(resources == [WebDAVResource(href: "/a", isCollection: true)])
    }

    @Test
    func `A zero time is no time`() {
        #expect(WebDAVMultistatus.date("Mon, 01 Jan 0001 00:00:00 GMT") == nil)
        #expect(WebDAVMultistatus.date("Thu, 01 Jan 1970 00:00:00 GMT") == nil)
        #expect(WebDAVMultistatus.date("Tue, 15 Oct 2024 08:30:00 GMT") == Date(timeIntervalSince1970: 1_728_981_000))
        #expect(WebDAVMultistatus.date("Tuesday, 15-Oct-24 08:30:00 GMT") == nil)
    }

    @Test
    func `A web page is not a multistatus`() {
        #expect(throws: WebDAVError.invalidResponse) {
            try WebDAVMultistatus.parse(Data("<html><body>Alist</body></html>".utf8))
        }
        #expect(throws: WebDAVError.invalidResponse) {
            try WebDAVMultistatus.parse(Data("not xml".utf8))
        }
    }

    @Test
    func `A connection never made carried nothing`() {
        #expect(!WebDAVError.mayHaveBeenSent(URLError(.cannotConnectToHost)))
        #expect(!WebDAVError.mayHaveBeenSent(URLError(.cannotFindHost)))
        #expect(WebDAVError.mayHaveBeenSent(URLError(.networkConnectionLost)))
        #expect(WebDAVError.mayHaveBeenSent(URLError(.timedOut)))
    }
}
