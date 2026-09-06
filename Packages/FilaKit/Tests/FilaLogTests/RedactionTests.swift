import Foundation
import Testing

@testable import FilaLog

// The buffer is shareable in one tap. These are the shapes a credential
// actually arrives in — a WebDAV `Authorization` header, a URL with userinfo,
// a spawned command's argument vector — and each one is a line somebody will
// eventually write without thinking about it.

@Suite("Redaction")
struct RedactionTests {
    private let placeholder = FilaLog.redactedPlaceholder

    @Test("Leaves an ordinary line exactly as it was")
    func passesThroughOrdinaryLines() {
        // Also the fast path: none of these carries `@`, `=` or `:`.
        for line in [
            "stat /private/var/db/dslocal refused errno 13 Permission denied",
            "→ list /private/var/mobile/Library/Preferences",
            "job 4 copy 2 source(s) → /private/var/mobile/Documents",
            "guard refused /private/var/mobile",
            "peer accepted pid 4213",
        ] {
            #expect(FilaLog.redacting(line) == line)
        }
    }

    @Test("An Authorization header loses its whole value")
    func authorizationHeader() {
        #expect(
            FilaLog.redacting("PROPFIND / Authorization: Basic Ym9iOmh1bnRlcjI=")
                == "PROPFIND / Authorization: \(placeholder)"
        )
        // Case is the client's choice, not ours.
        #expect(FilaLog.redacting("authorization: Bearer eyJhbGciOi").hasSuffix(placeholder))
        #expect(!FilaLog.redacting("Authorization: Basic Ym9iOmh1bnRlcjI=").contains("Ym9i"))
    }

    @Test("A bare auth scheme takes the token after it")
    func bareScheme() {
        #expect(FilaLog.redacting("sent Basic Ym9iOnB3") == "sent Basic \(placeholder)")
        #expect(FilaLog.redacting("sent Bearer eyJhbGciOi") == "sent Bearer \(placeholder)")
    }

    @Test("A URL keeps its user and loses its password")
    func urlUserInfo() {
        #expect(
            FilaLog.redacting("mount https://bob:hunter2@dav.example.com/share")
                == "mount https://bob:\(placeholder)@dav.example.com/share"
        )
        // Without a scheme too — that is how a credential reaches an argv.
        #expect(FilaLog.redacting("bob:hunter2@host") == "bob:\(placeholder)@host")
        // A port is not a password, and neither is a plain address.
        #expect(FilaLog.redacting("listening on 0.0.0.0:8080") == "listening on 0.0.0.0:8080")
        #expect(FilaLog.redacting("peer bob@host") == "peer bob@host")
    }

    @Test("An assignment whose key names a secret loses its value")
    func assignments() {
        #expect(FilaLog.redacting("GET /dav?password=hunter2") == "GET /dav?password=\(placeholder)")
        #expect(FilaLog.redacting("db_password=hunter2") == "db_password=\(placeholder)")
        #expect(FilaLog.redacting("token:hunter2") == "token:\(placeholder)")
        #expect(FilaLog.redacting("X-Auth-Token:abc123") == "X-Auth-Token:\(placeholder)")
        // Keys that name nothing secret are left alone, or the log stops being
        // readable at all.
        #expect(FilaLog.redacting("errno=13") == "errno=13")
        #expect(FilaLog.redacting("mode=0644 uid=501") == "mode=0644 uid=501")
    }

    @Test("A spawned command's password flag takes the argument after it")
    func commandArguments() {
        // Execution is no longer forbidden in this project, and an argv is the
        // most reliable place in any program for a password to end up.
        #expect(
            FilaLog.redacting("spawn /usr/bin/mount_webdav --password hunter2 /mnt")
                == "spawn /usr/bin/mount_webdav --password \(placeholder) /mnt"
        )
        #expect(FilaLog.redacting("run tool -p hunter2") == "run tool -p \(placeholder)")
        // Runs of spaces must not let the value slip past as an empty token.
        #expect(FilaLog.redacting("run tool -p   hunter2").contains(placeholder))
        #expect(!FilaLog.redacting("run tool -p   hunter2").contains("hunter2"))
    }

    @Test("Truncation cannot resurrect a secret by cutting the scrubber short")
    func withOverLongLines() {
        // The scrubber runs before the ring truncates, so a very long line is
        // scrubbed whole and only then cut.
        let padding = String(repeating: "a", count: FilaLogRing.maximumMessageByteCount)
        let scrubbed = FilaLog.redacting("\(padding) password=hunter2")
        #expect(!scrubbed.contains("hunter2"))
    }
}
