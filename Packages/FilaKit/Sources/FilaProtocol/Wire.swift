import Foundation

/// Names and limits shared by the app and `filad`.
///
/// The daemon is the only process on the device that runs as root, so this is
/// also the whole trust boundary: everything the app can ask for is one of the
/// operations below, and `PeerAuthenticator` decides whether it may ask at all.
public enum FilaProtocol {
    public static let version: UInt64 = 1
    public static let serviceName = "wiki.qaq.fila.service"
    public static let clientEntitlement = "wiki.qaq.fila.client"

    /// Resolved against the install root the daemon itself runs from, so one
    /// list covers roothide's randomized bootstrap and the fixed rootless
    /// `/var/jb` prefix. See `PeerAuthenticator.resolveInstalledClientPaths()`.
    public static let clientPaths = [
        "/Applications/Fila.app/Fila",
    ]

    /// A directory listing is paged: `readdir` + `fstatat` fills at most this
    /// many entries per reply, and the client asks again with the cursor it got
    /// back. A directory with 100k entries must never become one XPC message,
    /// and must never become one array inside the daemon.
    public static let directoryPageEntryCount = 512

    /// How many directory handles one peer may hold open mid-listing. A paged
    /// listing keeps its `DIR *` between pages — that is the only way a cursor
    /// stays correct while entries are being created and removed underneath it
    /// — so the count is capped and the oldest is closed when a peer wants
    /// another. Browsing needs one, search needs one, a stale one is a bug that
    /// must not accumulate.
    public static let concurrentListingsPerPeer = 8

    /// A listing that has not been asked for its next page in this long is
    /// closed. The app abandons a listing whenever the user navigates away, and
    /// nothing tells the daemon about that.
    public static let listingIdleTimeoutSeconds = 30.0

    /// Hard ceiling on any single reply. Nothing but metadata ever travels over
    /// the wire, so this is generous — file bytes go through a passed
    /// descriptor, never through a message.
    public static let maximumMessageByteCount = 2 * 1_024 * 1_024

    /// The largest extended-attribute value the daemon will put in a message.
    /// Anything bigger is a file in disguise and the caller wants a descriptor.
    public static let maximumExtendedAttributeByteCount = 256 * 1_024

    /// How many matches one `searchResult` message carries.
    ///
    /// A match is a directory path (at most `PATH_MAX`), a name, a symlink
    /// target and thirteen numbers — about 2.5 KB encoded in the worst case and
    /// nearer 150 bytes in practice. Sixty-four of the worst case is 160 KB,
    /// thirteen times under `maximumMessageByteCount`, and it is also the whole
    /// of what the daemon holds: a batch is filled, sent and dropped, so this
    /// number *is* the search's memory. Bigger buys nothing — the walk finds
    /// matches far slower than XPC delivers them — and smaller would send a
    /// message per match on a query that matches everything.
    public static let searchBatchMatchCount = 64

    /// How many matches a search reports before it stops walking.
    ///
    /// Not a display limit: a client that wants fewer stops early by cancelling
    /// the job. It is here so that "search `/` for `e`" ends, and so that the
    /// number the app explains to the user is the number the daemon enforces.
    /// Reaching it is reported as `SearchLimits.resultCount`, never applied in
    /// silence.
    public static let searchResultLimit = 10_000

    /// How deep a search descends. One open directory handle per level, so this
    /// is a memory bound as much as a loop bound — sixty-four levels is far
    /// past any real tree and costs a quarter of a megabyte of `DIR` buffers at
    /// its worst. A branch deeper than this is left unwalked and reported as
    /// `SearchLimits.depth`.
    public static let searchDepthLimit = 64

    /// How many terminals one peer may hold open. Each is a process and a
    /// pseudo-terminal — cheap in the daemon, which keeps neither the master
    /// descriptor nor a byte of the stream, but a device has a finite number of
    /// `/dev/ptmx` slots and a runaway client must not take them all.
    public static let terminalSessionsPerPeer = 8

    /// How long a hung-up terminal has to leave on its own before it is killed.
    /// A shell that took `SIGHUP` needs a moment to run its exit traps; one that
    /// ignored it does not get to stay.
    public static let terminalHangupGraceSeconds = 2.0
}

/// Every request the daemon serves.
///
/// There is deliberately no `readFile` / `writeFile`: see `openPath`.
public enum FilaOperation: UInt64, Sendable, CaseIterable {
    /// Protocol handshake. Establishes the version and reports the install root
    /// the daemon resolved for itself.
    case hello = 1

    /// One page of a directory's entries, with a cursor for the next page.
    case listDirectory = 2

    /// Full metadata for one path: `lstat`, BSD flags, xattr names, ACL
    /// presence, link target, on-disk size, and the guard's own verdict.
    case statPath = 3

    /// `open(2)` as root and hand the descriptor back over XPC. The bytes then
    /// flow between the client and the kernel with nothing in between: the
    /// daemon's memory stays flat regardless of file size, which is what keeps
    /// it under launchd's 6 MB jetsam cap.
    case openPath = 4

    /// mkdir, symlink, hardlink, or an empty regular file.
    case createNode = 5

    /// `renameat(2)` within one volume — the cheap move, and how the trash works.
    case rename = 6

    /// Mode, owner, group, times, BSD flags, extended attributes.
    case setAttributes = 7

    /// Start a long-running tree operation (copy, move, delete). Replies
    /// immediately with a job id; progress arrives as `jobEvent` messages.
    case startJob = 8

    /// Ask a running job to stop at its next callback.
    case cancelJob = 9

    case goodbye = 10

    /// Put a temp file the client has finished writing in place of the target:
    /// carry the original's mode, owner, times, xattrs and BSD flags across,
    /// then `rename(2)`. This is the only way a client saves a file, and the
    /// reason a power cut cannot leave half a system plist behind.
    case replaceItem = 11

    /// `statfs` for the volume a path lives on — the browser's footer, and the
    /// answer to "is this move a rename or a copy".
    case volumeInfo = 12

    /// One extended attribute's value, capped at
    /// `maximumExtendedAttributeByteCount`.
    case readExtendedAttribute = 13

    /// Daemon → client. Not a request: job progress and completion arrive
    /// unsolicited on the peer connection.
    case jobEvent = 14

    /// Daemon → client. A batch of matches from a running search job.
    ///
    /// Its own message rather than a case of `jobEvent`, because the two mean
    /// different things: `jobEvent` is lifecycle — how far along, and how it
    /// ended — and this is payload. A search that found nothing still reports
    /// progress and still completes.
    case searchResult = 15

    /// The daemon's log lines since a cursor, and the level it should capture
    /// at from here on.
    ///
    /// Polled rather than pushed, which is why it is a request and not a
    /// daemon → client message like the two above: the daemon's ring already
    /// holds the history, so this costs nothing until someone opens the log
    /// screen. See `FilaLog.Record` in `FilaLog` for the argument in full.
    /// Carries no file bytes and never will — a log line is names, numbers and
    /// paths.
    case fetchLog = 16

    /// Open a pseudo-terminal, run one program on it, and hand the **master
    /// descriptor** back over XPC — the same trade as `openPath`, for a stream
    /// instead of a file. The bytes flow between the app and the kernel with
    /// nothing in between, so the daemon's memory per session is a pid and a
    /// dispatch source, and a shell that prints a gigabyte costs it nothing.
    ///
    /// This is emphatically **not** "run this command". The request carries a
    /// path, a `TerminalUser` and a window size, and nothing else: there is no
    /// `arguments` field, no `environment` field, no shell string and no `-c`.
    /// The daemon composes argv (the executable and nothing more) and the whole
    /// environment itself, and an absent path means the login shell *it* picks.
    /// A caller therefore chooses which file on the device is exec'd, and which
    /// of two users it runs as, and cannot influence how — which is the
    /// narrowest shape this feature has, given that a shell is one of the files
    /// it can choose.
    ///
    /// The one program that takes an argument is the bootstrap's `dpkg`: a
    /// request may carry `FilaWireKey.package` instead of a path, and the
    /// daemon runs `dpkg -i <that file>` as root. The argument is a file the
    /// client chose, never a flag, and the flag is fixed here — so the feature
    /// is "install this package", not "run dpkg".
    case openTerminal = 17

    /// Hang one terminal up: `SIGHUP` to its process group, `SIGKILL` after
    /// `terminalHangupGraceSeconds`. A peer's terminals are also hung up when
    /// its connection goes away, so nothing this daemon spawned outlives the
    /// app that asked for it.
    case closeTerminal = 18

    /// Read the kernel mount table for the sidebar.
    case mountPoints = 19
}

public extension FilaOperation {
    /// What a log line calls this. Short, stable, and the same word the code
    /// around it uses — a log is only searchable if the vocabulary is fixed.
    var name: String {
        switch self {
        case .hello: return "hello"
        case .listDirectory: return "list"
        case .statPath: return "stat"
        case .openPath: return "open"
        case .createNode: return "create"
        case .rename: return "rename"
        case .setAttributes: return "setattr"
        case .startJob: return "startJob"
        case .cancelJob: return "cancelJob"
        case .goodbye: return "goodbye"
        case .replaceItem: return "replace"
        case .volumeInfo: return "volume"
        case .readExtendedAttribute: return "getxattr"
        case .jobEvent: return "jobEvent"
        case .searchResult: return "searchResult"
        case .fetchLog: return "fetchLog"
        case .openTerminal: return "openTerminal"
        case .closeTerminal: return "closeTerminal"
        case .mountPoints: return "mountPoints"
        }
    }
}

/// Who a terminal session runs as.
///
/// **A closed enum, and never a uid.** The obvious wire shape for this is a
/// number the client names, and that number is a "become anyone" primitive
/// handed to an untrusted app: a daemon that will `setuid` to whatever it is
/// told can be asked for `_securityd` as readily as for `mobile`. Two cases is
/// the whole feature the user asked for, so two cases is the whole wire.
///
/// Neither case ever *raises* privilege. `filad` is root because launchd
/// started it that way; `.root` is the absence of a drop, not an ascent, which
/// is why the harness — running as an ordinary developer — exercises the same
/// code path and gets an ordinary developer's shell.
public enum TerminalUser: Int64, Sendable, CaseIterable {
    /// Whoever `filad` is: root on a device, the developer in the harness.
    /// Nothing is dropped and there is no code here that could raise anything.
    ///
    /// Zero on the wire on purpose: a message with no user key at all decodes
    /// to this, which is what every terminal did before the choice existed.
    case root = 0

    /// The device's own unprivileged account, resolved by **name** from the
    /// passwd database rather than by a number anybody chose. The child drops
    /// to it before spawning the program and cannot climb back.
    case mobile = 1

    /// The account `.mobile` looks for. It is the user iOS runs everything
    /// non-system as, and the user this app itself is.
    public static let mobileName = "mobile"
}

public enum FilaReplyCode: Int64, Sendable, Codable {
    case success = 0
    case invalidRequest = 1
    case notPermitted = 2
    /// The path is one the daemon refuses to destroy. See `FilaGuard`.
    case protectedPath = 3
    case notFound = 4
    case operationFailed = 5
    case cancelled = 6
    /// An encrypted archive member, and no password or the wrong one. Its own
    /// code because the recovery is its own: ask, and run the job again.
    case wrongPassword = 7

    /// What a log line calls this. `protectedPath` reads as `guard` because
    /// that is the word for what happened — the guard refused it — and it is
    /// what someone reading the log will search for.
    public var name: String {
        switch self {
        case .success: return "ok"
        case .invalidRequest: return "invalid"
        case .notPermitted: return "refused"
        case .protectedPath: return "guard"
        case .notFound: return "missing"
        case .wrongPassword: return "password"
        case .operationFailed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}

/// Everything that can come back instead of an answer.
///
/// One type, because callers recover the same way for almost all of it: show
/// the message. The two that change behaviour are `protectedPath` — the UI may
/// offer the override — and `notPermitted`, which on a device means the daemon
/// refused the client rather than the kernel refusing the file.
public struct FilaFailure: Error, Sendable, Hashable, Codable {
    public var code: FilaReplyCode
    /// The `errno` the failing syscall set, or 0 when the refusal was the
    /// daemon's own.
    public var systemError: Int32
    /// The path the daemon was working on when it gave up, when it knows one.
    public var path: String?

    public init(code: FilaReplyCode, systemError: Int32 = 0, path: String? = nil) {
        self.code = code
        self.systemError = systemError
        self.path = path
    }

    /// `strerror(3)` for `systemError`, or nil when there was none.
    public var systemErrorDescription: String? {
        guard systemError != 0 else { return nil }
        return String(cString: strerror(systemError))
    }
}

public enum FilaWireKey {
    public static let version = "v"
    public static let operation = "op"
    public static let code = "code"
    public static let errno = "errno"
    public static let path = "path"
    public static let destination = "dst"
    public static let sources = "srcs"
    public static let cursor = "cursor"
    public static let entries = "entries"
    public static let descriptor = "fd"
    public static let openFlags = "oflag"
    public static let mode = "mode"
    public static let jobKind = "job"
    public static let jobIdentifier = "jobid"
    public static let jobPhase = "phase"
    public static let bytesDone = "done"
    public static let bytesTotal = "total"
    public static let itemsDone = "idone"
    public static let itemsTotal = "itotal"
    public static let installRoot = "root"
    public static let overrideGuard = "override"
    public static let details = "details"
    public static let volume = "vol"
    public static let mounts = "mounts"
    public static let attributeName = "aname"
    public static let attributeValue = "avalue"
    public static let attributes = "attrs"
    public static let nodeKind = "nkind"
    public static let linkTarget = "ltarget"
    public static let useTrash = "trash"
    public static let trashID = "trashID"
    public static let overwrite = "clobber"
    public static let recursive = "recursive"
    public static let exclusive = "excl"
    public static let matches = "hits"
    public static let searchLimits = "slim"
    public static let searchText = "qtext"
    public static let searchCaseSensitive = "qcase"
    public static let searchHidden = "qhidden"
    public static let searchGlob = "qglob"
    public static let archiveFormat = "aformat"
    public static let zipCompression = "azip"
    public static let zipEncryption = "aenc"
    public static let archivePassword = "apass"
    public static let archiveMembers = "amembers"
    public static let memberIndex = "i"
    public static let memberPath = "p"
    /// The newest log sequence the client already has; the daemon answers with
    /// what came after it.
    public static let logCursor = "lseq"
    /// The level the daemon should capture at from now on. Sent with every
    /// poll, so the switch in the log screen is live.
    public static let logLevel = "llvl"
    public static let logRecords = "lrec"
    public static let logDropped = "ldrop"

    public static let terminalIdentifier = "term"
    public static let terminalExited = "termExited"
    public static let terminalOwner = "termOwner"
    public static let columns = "cols"
    public static let rows = "rows"
    public static let workingDirectory = "cwd"
    public static let userIdentifier = "uid"
    /// A `TerminalUser` raw value — one of two — and never a uid. Absent means
    /// `.root`, which is what every terminal was before the choice existed.
    public static let terminalUser = "tuser"
    /// A Debian package for `dpkg -i`, in place of `path`. See
    /// `FilaOperation.openTerminal`.
    public static let package = "pkg"
    /// Whether a script's `#!` line may be honoured through the bootstrap's own
    /// interpreter. A bool and nothing else: the client never names the
    /// interpreter, and absent reads as off, which is what every terminal did
    /// before the setting existed.
    public static let redirectsScriptInterpreter = "shebang"
}
