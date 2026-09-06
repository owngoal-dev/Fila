import CryptoKit
import Foundation

/// Who is allowed to talk to this server, and how they prove it. One owner for
/// both schemes, so there is one place to read to know what the door is worth.
///
/// **Digest and Basic, in that order.** macOS's WebDAV client — the one behind
/// Finder's *Connect to Server*, and the whole point of this feature — will not
/// send a Basic password over an unencrypted connection without an interactive
/// "send it insecurely?" confirmation, and a mount that runs unattended simply
/// stops there. Digest never puts the password on the wire, so it gets past
/// that. Basic is offered beside it because browsers, `curl` and Windows all
/// speak it and some speak nothing else.
///
/// **What Digest is worth here.** The password, and only the password. The file
/// bytes still cross the network in the clear, and anyone who can read them can
/// also replay a request inside a nonce's lifetime — there is deliberately no
/// `nc` bookkeeping, because it would defend a channel that is already
/// readable. What it buys is that the credential itself is not left in
/// somebody's packet capture, reusable against every future session. That is a
/// real gain and the honest limit of it.
///
/// **There is no anonymous path.** Not a setting, not a special case: a server
/// that publishes `/` has no version of itself that is safe without one.
enum HTTPAuthentication {
    static let realm = "Fila"
    /// How long a nonce is accepted for. Long enough that a mount does not
    /// re-challenge constantly, short enough that a captured one is not a
    /// standing key.
    static let nonceLifetime: TimeInterval = 300

    /// Whether a request carries credentials this server accepts.
    static func isAuthorized(
        _ request: HTTPRequest,
        username: String,
        password: String,
        nonces: DigestNonces
    ) -> Bool {
        guard let header = request.header("authorization") else { return false }
        if header.lowercased().hasPrefix("digest ") {
            return verifyDigest(
                header,
                method: request.method,
                target: request.target,
                username: username,
                password: password,
                nonces: nonces
            )
        }
        return verifyBasic(header, username: username, password: password)
    }

    private static func verifyBasic(_ header: String, username: String, password: String) -> Bool {
        guard header.lowercased().hasPrefix("basic ") else { return false }
        let encoded = String(header.dropFirst("basic ".count)).trimmed
        guard let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8),
              // The first colon separates them, so a password may contain one.
              let separator = text.firstIndex(of: ":") else { return false }
        // Both halves always compared, so a wrong user name cannot be told from
        // a wrong password by how long the answer took.
        let userMatches = constantTimeEquals(String(text[..<separator]), username)
        let passwordMatches = constantTimeEquals(String(text[text.index(after: separator)...]), password)
        return userMatches && passwordMatches
    }

    /// `method` and `uri` go into the hash, which is what stops a lifted
    /// `PROPFIND` header from being replayed as a `DELETE`.
    ///
    /// The `uri` is also compared against the request line, and that comparison
    /// is the half that does the work: without it the client picks what goes
    /// into the hash, so a captured header stays valid against *every* path for
    /// the nonce's lifetime — whoever lifted it would choose the target. Decoded
    /// components rather than raw strings, because the header may spell the same
    /// resource in absolute form or with different escaping and both are the
    /// same resource.
    private static func verifyDigest(
        _ header: String,
        method: String,
        target: String,
        username: String,
        password: String,
        nonces: DigestNonces
    ) -> Bool {
        let fields = parse(header)
        guard fields["username"] == username,
              let nonce = fields["nonce"], nonces.isValid(nonce),
              let uri = fields["uri"],
              let response = fields["response"] else { return false }
        guard addresses(uri, sameResourceAs: target) else { return false }
        // Absent means MD5. Anything else is a scheme this does not implement,
        // and answering it with an MD5 comparison would be answering a
        // different question than the client asked.
        if let algorithm = fields["algorithm"], algorithm.uppercased() != "MD5" { return false }
        // A realm the client made up would mean a different HA1; comparing
        // against ours is what makes the digest specific to this server.
        if let claimed = fields["realm"], claimed != realm { return false }

        let ha1 = md5("\(username):\(realm):\(password)")
        let ha2 = md5("\(method):\(uri)")
        let expected: String
        if let qop = fields["qop"], let nonceCount = fields["nc"], let clientNonce = fields["cnonce"] {
            guard qop == "auth" else { return false }
            expected = md5("\(ha1):\(nonce):\(nonceCount):\(clientNonce):\(qop):\(ha2)")
        } else {
            expected = md5("\(ha1):\(nonce):\(ha2)")
        }
        return constantTimeEquals(expected, response.lowercased())
    }

    /// Whether the `uri` the client hashed names the same thing as the request
    /// line.
    ///
    /// Compared as decoded components, because a client may legitimately spell
    /// one resource as `/a/b` in the request line and as
    /// `http://host:8080/a/b` in the header, and both are that resource.
    ///
    /// A target this server would refuse anyway — one carrying `..`, an escaped
    /// separator, a NUL — has no components to compare, and falls back to a
    /// literal match. That is not a loophole: the path is rejected a few lines
    /// later whatever happens here, and the point of the fallback is that the
    /// client is told *400, that is not a path* rather than *401, wrong
    /// password*, which is the one of the two that is true.
    private static func addresses(_ uri: String, sameResourceAs target: String) -> Bool {
        if let claimed = RemotePath.components(of: uri), let asked = RemotePath.components(of: target) {
            return claimed == asked
        }
        return uri == target
    }

    /// The `WWW-Authenticate` values for a 401, strongest first. Two headers
    /// rather than one with two challenges in it: clients disagree about how to
    /// split a combined value, and one that splits it wrong sends nothing.
    ///
    /// `stale=true` is what a mount that has simply sat idle past
    /// `nonceLifetime` needs to hear. Without it a client reads the refusal as
    /// *wrong password* and asks the user for one, so an untouched mount would
    /// throw a dialog every five minutes.
    static func challenges(nonces: DigestNonces, for request: HTTPRequest? = nil) -> [String] {
        let stale = request.map(nonceExpired) ?? false
        var digest = #"Digest realm="\#(realm)", qop="auth", algorithm=MD5, nonce="\#(nonces.issue())", opaque="\#(realm)""#
        if stale { digest += ", stale=true" }
        return [digest, #"Basic realm="\#(realm)", charset="UTF-8""#]
    }

    /// Whether the refusal was a nonce this server no longer knows rather than
    /// a credential it never would have taken. It says nothing about whether
    /// the password was right, and it must not: `stale` only ever means "ask
    /// again with the new nonce", which is safe to say to anyone.
    private static func nonceExpired(_ request: HTTPRequest) -> Bool {
        guard let header = request.header("authorization"),
              header.lowercased().hasPrefix("digest ") else { return false }
        return parse(header)["nonce"] != nil
    }

    /// `key=value` pairs, values optionally quoted, commas inside quotes left
    /// alone.
    static func parse(_ header: String) -> [String: String] {
        var text = Substring(header)
        if text.lowercased().hasPrefix("digest ") { text = text.dropFirst("digest ".count) }

        var fields: [String: String] = [:]
        var name = ""
        var value = ""
        var readingName = true
        var quoted = false

        func commit() {
            let key = name.trimmed.lowercased()
            if !key.isEmpty { fields[key] = value.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            name = ""
            value = ""
            readingName = true
        }

        for character in text {
            if quoted {
                value.append(character)
                if character == "\"" { quoted = false }
                continue
            }
            switch character {
            case "=" where readingName:
                readingName = false
            case "\"" where !readingName:
                quoted = true
                value.append(character)
            case ",":
                commit()
            default:
                if readingName { name.append(character) } else { value.append(character) }
            }
        }
        commit()
        return fields
    }

    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Both halves always compared, so a near-miss cannot be told from a wild
    /// one by how long the answer took.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        for index in 0 ..< max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }
}

/// The nonces this server has handed out and still accepts.
///
/// A nonce is only ever one we issued: accepting an arbitrary string would let
/// a client choose the salt, which is the whole thing the nonce is for.
final class DigestNonces: @unchecked Sendable {
    /// A mount opens several connections and each challenges once; the cap is
    /// here so a client that asks for a challenge in a loop cannot grow this.
    static let limit = 256

    private let lock = NSLock()
    private var issued: [String: Date] = [:]

    func issue() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        // `SecRandomCopyBytes` would pull in Security for the same entropy;
        // this is the platform's own CSPRNG.
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0 ... 255) }
        let nonce = Data(bytes).base64EncodedString()

        lock.lock()
        defer { lock.unlock() }
        prune()
        // The oldest goes, never the whole map. A challenge is issued on every
        // *unauthenticated* request, so anyone who can reach the port could
        // otherwise invalidate every mounted client's nonce by asking 256
        // times without credentials.
        while issued.count >= Self.limit, let oldest = issued.min(by: { $0.value < $1.value })?.key {
            issued[oldest] = nil
        }
        issued[nonce] = Date()
        return nonce
    }

    func isValid(_ nonce: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        prune()
        return issued[nonce] != nil
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        issued.removeAll()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-HTTPAuthentication.nonceLifetime)
        issued = issued.filter { $0.value > cutoff }
    }
}
