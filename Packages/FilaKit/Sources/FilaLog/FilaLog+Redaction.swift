import Foundation

/// The one mechanical half of the privacy rule stated at the top of `FilaLog`.
///
/// It cannot stop someone logging a secret on purpose, and it is not trying
/// to. What it stops is the accident that actually happens: a request line, a
/// URL, or an argument vector goes into a log line whole, and one of the words
/// in it was a password. Every message goes through here on its way into the
/// ring *and* into `os_log`, so there is no unredacted copy anywhere.
///
/// The shapes it knows are the ones credentials arrive in:
///
/// | in                                   | out                                   |
/// |--------------------------------------|---------------------------------------|
/// | `Authorization: Basic dXNlcjpwdw==`  | `Authorization: <redacted>`           |
/// | `Bearer eyJhbGci…`                   | `Bearer <redacted>`                   |
/// | `PROPFIND https://bob:hunter2@dav/`  | `PROPFIND https://bob:<redacted>@dav/`|
/// | `?password=hunter2`                  | `?password=<redacted>`                |
/// | `mount --password hunter2`           | `mount --password <redacted>`         |
/// | `token:hunter2`                      | `token:<redacted>`                    |
///
/// Over-redaction is the safe direction and the list leans that way — a `key=`
/// that turns out to have been harmless costs a reader nothing, and this
/// module never sees an extended attribute's value in the first place.
public extension FilaLog {
    static let redactedPlaceholder = "<redacted>"

    /// Tokens that announce a credential in the token after them. A command's
    /// password flag and an auth scheme are the same shape and the same fix,
    /// so they share one list rather than two identical branches.
    private static let announcesASecret: Set<String> = [
        "-p", "--password", "--passwd", "--pass",
        "--token", "--secret", "--apikey", "--api-key",
        "basic", "bearer", "digest",
    ]

    /// A header whose entire remaining value is the credential.
    private static let secretHeaders: Set<String> = [
        "authorization:", "proxy-authorization:", "www-authenticate:",
    ]

    /// Matched against the end of the key in `key=value` and `key:value`, so
    /// `db_password=` and `X-Auth-Token:` are caught along with the bare words.
    private static let secretKeys = [
        "password", "passwd", "pass", "pw",
        "token", "secret", "apikey", "api_key", "key",
        "auth", "credential", "credentials",
    ]

    /// The message with anything credential-shaped replaced.
    ///
    /// Every line is split and walked, with no character-based early-out — the
    /// obvious one (skip a line with no `@`, `=` or `:`) is wrong, because
    /// `Basic Ym9iOnB3` and `--password hunter2` contain none of the three and
    /// are the two shapes most worth catching. The cost is a split and a
    /// lowercase per token, a microsecond or so; verbose writes a line per XPC
    /// round trip, which is hundreds a second at its worst, not thousands.
    static func redacting(_ message: String) -> String {
        var tokens = message.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var redactNextToken = false
        var index = 0
        while index < tokens.count {
            defer { index += 1 }
            let token = tokens[index]
            // A run of spaces is not the value the flag was pointing at.
            if token.isEmpty { continue }

            if redactNextToken {
                redactNextToken = false
                tokens[index] = redactedPlaceholder
                continue
            }

            let lowered = token.lowercased()
            if secretHeaders.contains(lowered) {
                // A header's value is the credential in full, and it may be
                // several tokens (`Basic` plus the payload). Nothing after it
                // on the line is worth more than the leak would cost.
                tokens.replaceSubrange((index + 1)..., with: [redactedPlaceholder])
                break
            }
            if announcesASecret.contains(lowered) {
                redactNextToken = true
                continue
            }
            if let redacted = redactingUserInfo(token) {
                tokens[index] = redacted
                continue
            }
            if let redacted = redactingAssignment(token) {
                tokens[index] = redacted
            }
        }
        return tokens.joined(separator: " ")
    }

    /// `scheme://user:pass@host` and the bare `user:pass@host` both. The user
    /// stays — knowing *which* account failed to authenticate is most of the
    /// diagnosis, and it is not the secret.
    private static func redactingUserInfo(_ token: String) -> String? {
        // The last `@`, because a password may legally contain one.
        guard let at = token.lastIndex(of: "@") else { return nil }
        let head = token[..<at]
        let start = head.range(of: "//")?.upperBound ?? head.startIndex
        guard let colon = head[start...].firstIndex(of: ":") else { return nil }
        return token[...colon] + redactedPlaceholder + token[at...]
    }

    /// `key=value` and `key:value`, when the key ends in a word that names a
    /// secret. A port (`host:8080`) and a time survive because neither key is
    /// on the list.
    private static func redactingAssignment(_ token: String) -> String? {
        // Indexed on `token` itself and only the key is lowercased, so the cut
        // is never taken against a string whose length lowercasing changed.
        guard let separator = token.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return nil }
        let key = token[..<separator].lowercased()
        guard !key.isEmpty, secretKeys.contains(where: { key.hasSuffix($0) }) else { return nil }
        return token[...separator] + redactedPlaceholder
    }
}
