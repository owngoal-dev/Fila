import Darwin
import Dispatch
import FilaProtocol
import Foundation

/// What a terminal session is asked to run.
///
/// There is deliberately **no `arguments` and no `environment`**. The wire
/// carries a path, a user, a directory and a window size; argv and the whole
/// environment are composed here, in the root process, from a plan the client
/// cannot reach. That is the difference between "open a terminal on this file"
/// and "run this command as root", and the second one is not an operation this
/// daemon has.
///
/// `user` is the one thing here that is about privilege, and it is a closed
/// enum for the reason `TerminalUser` states: *which* of two users is a
/// feature, *any* uid is a different one.
public struct TerminalRequest: Sendable {
    /// The program to run, or nil for the login shell `TerminalPlan` picks.
    public var executable: String?
    /// A Debian package to install with the bootstrap's own `dpkg -i`, on a
    /// terminal so its output is the user's to read. The one program this
    /// daemon runs with an argument, and the argument is a file the client
    /// chose, never a flag: the argv is `dpkg -i <package>` and nothing else,
    /// composed here. Refused with `executable` set, and refused for `.mobile`
    /// — dpkg as anyone but root has nothing to install into.
    public var package: String?
    /// Who it runs as. `.root` drops nothing and raises nothing.
    public var user: TerminalUser
    /// Whether a `#!` line may be honoured through the bootstrap's own copy of
    /// the interpreter it names. Off, `executable` is exec'd as it stands and
    /// the kernel decides — which on a rootless device means a script written
    /// `#!/bin/sh` does not run at all, because there is no `/bin/sh` there.
    ///
    /// A bool, and deliberately nothing more: it cannot name an interpreter,
    /// an argument or an environment. What it turns on is a lookup this daemon
    /// performs on the script's own first line.
    public var redirectsScriptInterpreter: Bool
    /// Where the session starts. Ignored when it is not a directory the daemon
    /// can enter; the plan's home is the fallback, and `/` the fallback's.
    public var workingDirectory: String?
    public var columns: UInt16
    public var rows: UInt16

    public init(
        executable: String? = nil,
        package: String? = nil,
        user: TerminalUser = .root,
        redirectsScriptInterpreter: Bool = false,
        workingDirectory: String? = nil,
        columns: UInt16 = 80,
        rows: UInt16 = 24
    ) {
        self.executable = executable
        self.package = package
        self.user = user
        self.redirectsScriptInterpreter = redirectsScriptInterpreter
        self.workingDirectory = workingDirectory
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
}

/// A live terminal: the master descriptor for the caller, and the process to
/// hang up when the caller is done with it.
public struct TerminalLaunch: Sendable {
    /// The pseudo-terminal master. **The caller owns it and must `close(2)` it**
    /// — in the daemon that means handing it to XPC and closing immediately, so
    /// that no descriptor and no byte of the stream stays in this process.
    public let descriptor: Int32
    public let process: TerminalProcess
    /// What was actually exec'd, resolved. Shown to the user, so they can tell
    /// a symlink from what it pointed at.
    public let executable: String
    /// Who it actually runs as. Sent to the client so the UI can say so rather
    /// than assume it: the app asked for one of two users, and this is the
    /// answer, which is the direction of that sentence that cannot lie. It is
    /// only ever reported for a child that reached `execve` — a drop that
    /// failed never gets this far, because the child refuses to exec and says
    /// so down the report pipe.
    public let userIdentifier: uid_t
}

public extension FileOperations {
    /// Open a pseudo-terminal and run one program on it, as root or as
    /// `mobile`.
    ///
    /// **What this spawns:** one executable regular file, with an argv of
    /// exactly itself; the interpreter that file's own `#!` line names, with an
    /// argv of itself and that file, when the request allows it; the login
    /// shell chosen by `TerminalPlan.loginShell` with `-il`; or the bootstrap's
    /// `dpkg` with `-i` and one package file, as root only. Every one of those
    /// argv lists is composed here and none of them can carry a flag the client
    /// or the file chose. **As whom:** whoever `filad` is — root on a device — or the
    /// `mobile` account resolved by name, and nothing else, because the wire
    /// carries a two-case `TerminalUser` and not a uid. **What it refuses:**
    /// argv, an environment, a shell string, any `-c`, a package that is not a
    /// regular file, anything that is not a
    /// real executable regular file, and any climb in privilege — the only
    /// credential change here is downward, it happens in the child before
    /// `execve`, and the child proves it took by checking that it can no longer
    /// become root.
    ///
    /// A root session is the deliberate default for a *root file manager* —
    /// one that could not read the directory the user was just browsing would
    /// be a decoration — and it is what Filza's terminal does. `mobile` is
    /// there because running a downloaded binary with the whole device behind
    /// it is not always what the user wants, and asking is cheaper than
    /// undoing.
    func openTerminal(_ request: TerminalRequest) throws -> TerminalLaunch {
        let layout = BootstrapLayout(installRoot: bootstrapRoot)
        let plan = try TerminalPlan(request: request, layout: layout)
        return try TerminalSpawn.run(plan, columns: request.columns, rows: request.rows)
    }
}

// MARK: - Bootstrap vocabulary

/// Which of the three jailbreak layouts we are running under, and how a path
/// has to be spelled for whoever is going to read it.
///
/// Mixing the two spellings up is the classic bootstrap-path bug, so each
/// direction is its own function and every call site names the one it means.
/// The rule, copied from iGhostVT (which took it from roothide's own NewTerm):
///
/// - The path handed to `execve` must be what the **kernel** wants, because
///   neither the kernel nor `filad` is linked against libvroot — `resolve`.
/// - Every path that goes *into the environment* must be in the bootstrap's own
///   vocabulary, because the programs that read it are vroot-linked under
///   roothide (unprefixed, the jbroot is their `/`) and prefix-compiled under
///   rootless (`/var/jb/...`) — `bootstrapPath` and `systemPath`.
struct BootstrapLayout {
    enum Kind: Equatable {
        /// Rootful, or the Mac. Every mapping is the identity.
        case none
        /// A fixed prefix whose binaries speak real paths.
        case rootless(prefix: String)
        /// A randomly named jbroot whose binaries are vroot-linked, with the
        /// untouched iOS filesystem bridged back in at `/rootfs`.
        case roothide(jbroot: String)
    }

    /// Rootless bootstraps all agree on this, and their binaries carry it
    /// compiled in — so this literal, not whatever it resolves to, is what goes
    /// back into paths.
    static let rootlessPrefix = "/var/jb"

    let kind: Kind

    /// A layout stated outright. On a device every kind is derived from the
    /// daemon's own install root; the harness cannot make a `/var/jb` exist on
    /// the Mac, and the rootless remap is the whole of what needs testing.
    init(kind: Kind) { self.kind = kind }

    init(installRoot: String) {
        var isBootstrap: Bool {
            // A jbroot has the daemon in it, at the layout `InstallRoot` peeled
            // off to get here. Without this check *any* non-empty prefix is
            // taken for a jbroot — including an app bundle, if the daemon is
            // ever shipped inside one again — and every path in the session
            // would be built against a directory that has no bootstrap in it.
            var info = stat()
            return stat(installRoot + "/usr/libexec", &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        }
        if installRoot.isEmpty {
            kind = .none
        } else if (try? FilaPath.resolve(Self.rootlessPrefix)) == installRoot {
            // A rootless bootstrap may keep its files in a randomly named
            // directory with `/var/jb` symlinked at it, and `InstallRoot` is
            // canonical — so compare canonical against canonical and keep the
            // literal prefix, which is the one its binaries were built against.
            kind = .rootless(prefix: Self.rootlessPrefix)
        } else {
            kind = isBootstrap ? .roothide(jbroot: installRoot) : .none
        }
    }

    /// How the bootstrap's own programs spell one of *its* files.
    func bootstrapPath(_ path: String) -> String {
        switch kind {
        case .none, .roothide: path
        case let .rootless(prefix): prefix + path
        }
    }

    /// How those same programs spell a file on the untouched iOS filesystem.
    func systemPath(_ path: String) -> String {
        switch kind {
        case .none, .rootless: path
        case .roothide: "/rootfs" + path
        }
    }

    /// A path in the bootstrap's vocabulary, as a syscall wants it.
    func resolve(_ path: String) -> String {
        switch kind {
        case .none, .rootless: path
        case let .roothide(jbroot): path.hasPrefix("/") ? jbroot + path : path
        }
    }

    func isExecutableFile(_ bootstrapPath: String) -> Bool {
        TerminalPlan.isExecutableFile(resolve(bootstrapPath))
    }
}

// MARK: - What runs, and in what world

/// Everything the child needs, decided before anything is forked.
struct TerminalPlan {
    /// Real path, for `execve`. Always `arguments[0]` as well — nothing here
    /// ever runs a program under a name that is not its own.
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    /// Already checked to be a directory; nil means the child stays in the
    /// daemon's own, which is launchd's `/`.
    var workingDirectory: String?
    /// **Non-nil only when the child must become someone else.** Nil is not
    /// "run as root" — it is "change nothing", which is the only honest
    /// spelling of a process that never raises privilege. Where this is set,
    /// the child drops to it before `execve` and verifies it cannot climb back.
    var credential: Credential?

    /// The ids a child drops to, resolved from a passwd entry in the parent so
    /// that nothing between `fork` and `execve` has to read a database.
    struct Credential {
        var uid: uid_t
        var gid: gid_t
    }

    /// The shells a bootstrap installs, most capable first, in the generic
    /// spelling `BootstrapLayout.bootstrapPath` turns into the bootstrap's own.
    private static let bootstrapShells = ["/bin/zsh", "/bin/bash", "/bin/sh"]

    /// Where every bootstrap keeps dpkg, in the generic spelling. The one
    /// program a `TerminalRequest.package` runs.
    private static let packageInstaller = "/usr/bin/dpkg"

    /// Where the bootstrap keeps its tools, and where iOS keeps its own. The
    /// bootstrap's come first: without the second half a shell reaches
    /// everything the bootstrap installed and nothing the system ships.
    private static let bootstrapBinaryDirectories = [
        "/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin",
    ]
    private static let systemBinaryDirectories = ["/usr/sbin", "/usr/bin", "/sbin", "/bin"]

    init(request: TerminalRequest, layout: BootstrapLayout) throws {
        let session = try Self.sessionUser(request.user, layout: layout)
        let user = session.entry
        credential = session.credential
        // The environment follows the user, not the daemon: `HOME`, `USER` and
        // `LOGNAME` come from the entry resolved just above, so a `mobile`
        // session lands in `/var/mobile` and its shell reads `mobile`'s dotfiles
        // rather than root's. A dropped child that still had root's `HOME` would
        // be a shell that cannot write its own history and, worse, one that
        // reads configuration only root should have chosen.
        var environment = Self.baseEnvironment(user: user, layout: layout)

        if let package = request.package {
            // The one program that gets an argument, and the argument is the
            // file the client chose — never a flag. Root only: dpkg as `mobile`
            // has nowhere to install into. A request naming both a program and
            // a package is asking for a shape this plan does not spell.
            guard request.executable == nil, request.user == .root else {
                throw FilaFailure(code: .invalidRequest, path: package)
            }
            let resolved = try FilaPath.resolve(package)
            var info = stat()
            guard stat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw FilaFailure(code: .notFound, systemError: ENOENT, path: package)
            }
            let dpkg = layout.resolve(layout.bootstrapPath(Self.packageInstaller))
            guard Self.isExecutableFile(dpkg) else {
                throw FilaFailure(code: .notFound, systemError: ENOENT, path: dpkg)
            }
            executable = dpkg
            // dpkg opens the package by the name it is handed, and under
            // roothide it is vroot-linked: a file on the untouched filesystem
            // is spelled the way `systemPath` spells it, or dpkg looks for it
            // inside the jbroot and reports it missing.
            //
            // ponytail: a package whose postinst restarts filad (Fila's own
            // deb) takes this daemon down mid-install. dpkg is in its own
            // session and the app holds the pty master, so the install runs
            // to the end and its output still arrives — but the restarted
            // daemon no longer holds the pid, and `closeTerminal` cannot hang
            // it up. The upgrade is the device updater's exclusive staging
            // directory and detached install, if self-update from the browser
            // is ever wanted.
            arguments = [dpkg, "-i", layout.systemPath(resolved)]
        } else if let requested = request.executable {
            // The one thing the client chooses. It must be a real, executable,
            // regular file — a directory, a device node or a text file with no
            // execute bit is a mistake, not a program — and it is exec'd with
            // an argv of exactly itself.
            let resolved = try FilaPath.resolve(requested)
            guard Self.isExecutableFile(resolved) else {
                throw FilaFailure(code: .notPermitted, systemError: EACCES, path: requested)
            }
            if request.redirectsScriptInterpreter, let named = Self.shebangInterpreter(of: resolved) {
                guard let interpreter = Self.program(named: named, layout: layout) else {
                    // Named, and not there in either spelling. Said with the
                    // interpreter as the path, because "sh: no such file" is
                    // the answer and "<script>: no such file" — which is what
                    // the kernel would have reported — names the one file that
                    // does exist.
                    throw FilaFailure(code: .notFound, systemError: ENOENT, path: named)
                }
                executable = interpreter
                // The interpreter opens the script by the name it is handed,
                // and under roothide it is vroot-linked: the same reasoning as
                // dpkg's package argument, and the same `systemPath` for it.
                arguments = [interpreter, layout.systemPath(resolved)]
            } else {
                executable = resolved
                arguments = [resolved]
            }
            if let shell = user?.shell, !shell.isEmpty { environment["SHELL"] = shell }
        } else {
            // Spawned directly rather than through the bootstrap's `login`, for
            // the reason iGhostVT documents: Procursus' `/etc/pam.d/login` runs
            // `pam_launchd.so`, which moves the session into a per-user
            // bootstrap namespace that cannot reach `com.apple.dnssd.service`,
            // and every `login`-spawned process then loses DNS entirely.
            guard let shell = Self.loginShell(user: user, layout: layout) else {
                // No path: nothing in particular was missing. The bootstrap's
                // passwd entry named nothing runnable and neither did any of
                // the fallbacks, which on a device means no shell is installed.
                throw FilaFailure(code: .notFound, systemError: ENOENT)
            }
            executable = layout.resolve(shell)
            arguments = [executable, "-il"]
            environment["SHELL"] = shell
        }

        self.environment = environment
        workingDirectory = Self.firstDirectory([
            request.workingDirectory,
            user.map { layout.resolve($0.home) },
            user?.home,
        ])
    }

    /// Who the session runs as: the passwd entry its environment and login
    /// shell come from, and the credential the child has to take on — or none,
    /// when there is nothing to change.
    ///
    /// `.root` resolves to *this process*, and deliberately not to uid 0. The
    /// daemon is root because launchd started it that way; there is no call
    /// here that raises privilege and there must never be one, so "root" is the
    /// name of the absence of a drop. That is also what lets the harness run
    /// this exact path as an ordinary developer.
    ///
    /// `.mobile` is resolved by **name** — `TerminalUser.mobileName` — because
    /// the alternative is a number, and a number on the wire is the "become
    /// anyone" primitive `TerminalUser` exists to refuse. When the daemon is
    /// not root there is nothing to drop and no way to drop it, so the answer
    /// is this process again; on a device that branch is unreachable, and in
    /// the harness it is the whole of what can be tested.
    private static func sessionUser(
        _ requested: TerminalUser,
        layout: BootstrapLayout
    ) throws -> (entry: PasswdEntry?, credential: Credential?) {
        guard requested == .mobile, getuid() == 0 else {
            return (PasswdEntry.current(layout: layout), nil)
        }
        guard let mobile = PasswdEntry.named(TerminalUser.mobileName, layout: layout) else {
            // Nothing to fall back to. Running the session as root because
            // `mobile` could not be looked up would silently give the user the
            // opposite of what they asked for, on the one screen where the
            // difference is the entire question.
            throw FilaFailure(code: .notFound, systemError: ENOENT)
        }
        return (mobile, Credential(uid: mobile.uid, gid: mobile.gid))
    }

    /// What every session's program finds in its environment, shell or not: the
    /// terminal's identity, the user's, and a `PATH` — the daemon's own is
    /// launchd's, which holds nothing a shell can use.
    private static func baseEnvironment(user: PasswdEntry?, layout: BootstrapLayout) -> [String: String] {
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "Fila",
            "LC_TERMINAL": "Fila",
            // `LC_CTYPE` alone, never `LANG` and never `LC_ALL`: both of those
            // set every category at once, iOS ships exactly one locale
            // directory and it holds `LC_CTYPE` and nothing else, so both fail
            // outright and drop the process back to C — where CJK is counted
            // and drawn one byte at a time as the user types it.
            "LC_CTYPE": preferredLocale,
            "PATH": path(layout: layout),
        ]
        if let user {
            environment["HOME"] = user.home
            environment["USER"] = user.name
            environment["LOGNAME"] = user.name
        }
        return environment
    }

    private static func path(layout: BootstrapLayout) -> String {
        var directories: [String] = []
        let candidates = bootstrapBinaryDirectories.map(layout.bootstrapPath)
            + systemBinaryDirectories.map(layout.systemPath)
        for directory in candidates where !directories.contains(directory) {
            directories.append(directory)
        }
        return directories.joined(separator: ":")
    }

    /// The first locale whose `LC_CTYPE` the C library can actually load.
    /// Naming one it cannot is worse than naming none. Resolved once: the
    /// answer is a property of the system, not of a session.
    private static let preferredLocale: String = ["en_US.UTF-8", "UTF-8"].first {
        var info = stat()
        return stat("/usr/share/locale/\($0)/LC_CTYPE", &info) == 0
    } ?? "UTF-8"

    /// Which shell a session gets.
    ///
    /// **The bootstrap's own shell wins over the passwd entry's, and that
    /// inversion is the point.** Reading the shell out of the passwd database
    /// is the obvious rule and the next person to read this will assume it is
    /// the right one, so here is why it is not: the entry is looked up for
    /// whoever `filad` is, root, and root's shell field is whatever the last
    /// thing to write that file left there. On the development device it still
    /// reads `/iosbinpack64/bin/zsh` — a zsh 5.0.8 left behind by a bootstrap
    /// that is long gone. It is a regular file, it has its execute bit, so
    /// every "is it runnable" test passes it; it then starts and immediately
    /// fails to `dlopen` its own `zsh/zle` module, because the modules that
    /// matched it went with the bootstrap that installed it. The user gets a
    /// shell with no line editing, no history and no completion, and an error
    /// on the first line. Run side by side under `forkpty` as root on that
    /// device, the legacy binary emitted 370 bytes ending in that dlopen
    /// failure and the bootstrap's own emitted 291 bytes of prompt and escape
    /// sequences.
    ///
    /// So the rule is: the shell that shipped with **the bootstrap this daemon
    /// is installed in** is the one whose modules, `/etc/zshrc` and library
    /// paths are known to match it, and it goes first. The passwd entry is the
    /// fallback, which is where an inherited path belongs — it still covers the
    /// bootstrap that installs its shell somewhere these three names miss.
    ///
    /// `bootstrapPath` is what makes the first list mean the bootstrap's own
    /// files: under rootless it turns `/bin/zsh` into `/var/jb/bin/zsh`, and
    /// under roothide it is the identity because those binaries are vroot-linked
    /// (`resolve` puts the jbroot on for the syscall). Never a literal prefix
    /// here — the prefix comes from `InstallRoot` by way of `BootstrapLayout`.
    private static func loginShell(user: PasswdEntry?, layout: BootstrapLayout) -> String? {
        if let shell = bootstrapShells.map(layout.bootstrapPath).first(where: layout.isExecutableFile) {
            return shell
        }
        if let shell = user?.shell, !shell.isEmpty, layout.isExecutableFile(shell) { return shell }
        return nil
    }

    /// XNU reads a shebang out of the first page and gives up at 512 bytes, so
    /// there is nothing past that to read and no reason to read further. The
    /// bound is the point: this is the one place the daemon looks inside a file
    /// the user chose, and a file manager's files are gigabytes.
    private static let shebangLimit = 512

    /// The interpreter a script's `#!` line names, or nil when the file does
    /// not begin with one.
    ///
    /// **Only the interpreter, never the argument after it.** A shebang may
    /// carry one, and passing it on would be the daemon running a program with
    /// a flag the file chose — the shape `openTerminal` exists to refuse. The
    /// single exception is `env`, where the word after it *is* the interpreter
    /// rather than an option; anything that looks like a flag or an assignment
    /// ends the read, because `env -S` and `env NAME=value` are both ways of
    /// spelling a command line.
    private static func shebangInterpreter(of path: String) -> String? {
        // `O_NOFOLLOW` on an already-canonical path: realpath resolved the last
        // component, so this only refuses one that was swapped for a symlink
        // since. Reading is all that happens here — the file was already
        // required to be an executable regular file.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        let wanted = shebangLimit
        var buffer = [UInt8](repeating: 0, count: wanted)
        var filled = 0
        while filled < wanted {
            let got = buffer.withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress?.advanced(by: filled), wanted - filled)
            }
            if got > 0 { filled += got; continue }
            if got < 0, Darwin.errno == EINTR { continue }
            break
        }
        guard filled > 2, buffer[0] == UInt8(ascii: "#"), buffer[1] == UInt8(ascii: "!") else { return nil }
        let line = buffer[2 ..< filled].prefix { $0 != UInt8(ascii: "\n") && $0 != 0 }
        let fields = String(decoding: line, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            .map(String.init)
        guard let first = fields.first else { return nil }
        guard first.split(separator: "/").last == "env" else { return first }
        guard let named = fields.dropFirst().first,
              !named.hasPrefix("-"), !named.contains("=") else { return nil }
        return named
    }

    /// Where a program the shebang named actually lives, as a syscall wants it,
    /// or nil when no spelling of it is runnable.
    ///
    /// **The bootstrap's copy is the fallback, not the first answer.** Every
    /// script on every machine is written `#!/bin/sh`, and on a rootless device
    /// that file does not exist — `/var/jb/bin/sh` is the one that does. So the
    /// literal path is tried as written, and only a miss reaches for the
    /// bootstrap's spelling of the same name. A bare word only ever arrives
    /// from `env`, and is looked for in the directories `PATH` names, in the
    /// same order the session's own `PATH` lists them.
    private static func program(named name: String, layout: BootstrapLayout) -> String? {
        if name.hasPrefix("/") {
            for candidate in [name, layout.bootstrapPath(name)] {
                let real = layout.resolve(candidate)
                if isExecutableFile(real) { return real }
            }
            return nil
        }
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let directories = bootstrapBinaryDirectories.map(layout.bootstrapPath)
            + systemBinaryDirectories.map(layout.systemPath)
        for directory in directories {
            let real = layout.resolve(directory + "/" + name)
            if isExecutableFile(real) { return real }
        }
        return nil
    }

    static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        // Asked as the daemon, which as root says yes to any execute bit. For a
        // session that is about to drop to `mobile` that is the permissive
        // answer rather than the exact one — a root-only binary passes here and
        // then fails in the child. It fails legibly, which is the part that
        // matters: `execve` sets `EACCES`, the child writes it down the report
        // pipe, and the screen says "Permission denied" instead of opening a
        // terminal that closes itself. Checking with `mobile`'s credentials
        // instead would mean holding them in the parent, and the parent is the
        // one process here that must never wear someone else's.
        return access(path, X_OK) == 0
    }

    private static func firstDirectory(_ candidates: [String?]) -> String? {
        for case let path? in candidates {
            var info = stat()
            if stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { return path }
        }
        return nil
    }
}

/// One line of the bootstrap's own `/etc/passwd`.
///
/// Read from the bootstrap's root rather than through `getpwuid`, because libc
/// answers from the *system's* database: on a jailbroken device root's shell
/// there is `/bin/sh` (which does not exist) and its home is `/var/root`, while
/// the bootstrap's entry names the zsh the user actually installed, already in
/// the spelling its own programs use.
struct PasswdEntry {
    var name: String
    var uid: uid_t
    var gid: gid_t
    var home: String
    var shell: String

    /// The entry for whoever this process is — root on the device.
    static func current(layout: BootstrapLayout) -> PasswdEntry? {
        let uid = getuid()
        return bootstrapEntry(layout: layout) { $0.uid == uid } ?? systemEntry(getpwuid(uid))
    }

    /// The entry for a named account. Only ever called with
    /// `TerminalUser.mobileName`: a name is the whole of what a caller can ask
    /// for, and it is not the caller who supplies even that.
    static func named(_ name: String, layout: BootstrapLayout) -> PasswdEntry? {
        bootstrapEntry(layout: layout) { $0.name == name } ?? systemEntry(getpwnam(name))
    }

    private static func bootstrapEntry(
        layout: BootstrapLayout,
        matching: (PasswdEntry) -> Bool
    ) -> PasswdEntry? {
        let path = layout.resolve(layout.bootstrapPath("/etc/passwd"))
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 7, let uid = uid_t(fields[2]), let gid = gid_t(fields[3]) else { continue }
            let entry = PasswdEntry(
                name: String(fields[0]),
                uid: uid,
                gid: gid,
                home: String(fields[5]),
                shell: String(fields[6])
            )
            if matching(entry) { return entry }
        }
        return nil
    }

    private static func systemEntry(_ entry: UnsafeMutablePointer<passwd>?) -> PasswdEntry? {
        guard let entry else { return nil }
        return PasswdEntry(
            name: String(cString: entry.pointee.pw_name),
            uid: entry.pointee.pw_uid,
            gid: entry.pointee.pw_gid,
            home: String(cString: entry.pointee.pw_dir),
            shell: String(cString: entry.pointee.pw_shell)
        )
    }
}

// MARK: - The fork

/// The only place in this project that creates a process.
enum TerminalSpawn {
    static func run(_ plan: TerminalPlan, columns: UInt16, rows: UInt16) throws -> TerminalLaunch {
        // Everything the child touches is built here, before the fork: between
        // `fork` and `execve` a Swift process may only make async-signal-safe
        // calls, and allocating an array is not one of them.
        let argv = CStringArray(plan.arguments)
        let envp = CStringArray(plan.environment.map { "\($0.key)=\($0.value)" }.sorted())
        let executable = strdup(plan.executable)
        let directory = plan.workingDirectory.flatMap { strdup($0) }
        // Read out here, so the child branch touches nothing but locals of
        // trivial type — no property access, no ARC, no allocation.
        let argvPointer = argv.pointer
        let envpPointer = envp.pointer
        // The passwd lookup that produced these ran in the parent for the same
        // reason: `getpwnam` reads a database and allocates, and between `fork`
        // and `execve` only async-signal-safe calls may run. What crosses the
        // fork is three integers.
        let mustDrop = plan.credential != nil
        let dropUID = plan.credential?.uid ?? 0
        let dropGID = plan.credential?.gid ?? 0
        defer {
            argv.deallocate()
            envp.deallocate()
            free(executable)
            free(directory)
        }

        // How the child says why it never reached `execve`. The write end is
        // close-on-exec, so a successful exec closes it and the parent reads
        // EOF; anything else arrives as an errno. Without it the only evidence
        // is a terminal that opens and closes again, and the overwhelmingly
        // likely cause on a jailbroken device — a binary AMFI refuses, `EPERM`
        // — would be indistinguishable from a missing file.
        var reportPipe: [Int32] = [-1, -1]
        guard pipe(&reportPipe) == 0 else { throw FilaFailure(errno: Darwin.errno) }
        let reportRead = reportPipe[0]
        let reportWrite = reportPipe[1]
        guard fcntl(reportWrite, F_SETFD, FD_CLOEXEC) == 0 else {
            let failure = FilaFailure(errno: Darwin.errno, path: plan.executable)
            close(reportRead)
            close(reportWrite)
            throw failure
        }
        let report = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        defer { report.deallocate() }

        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        // `forkpty` does the parts that have to be right and are easy to get
        // wrong: `setsid`, `TIOCSCTTY` on the slave, and the slave onto 0/1/2.
        let pid = forkpty(&master, nil, nil, &size)
        if pid == 0 {
            close(reportRead)
            // The daemon's descriptors are close-on-exec, but it holds open
            // directories, jobs and an XPC connection to root; the sweep is
            // what guarantees none of them reaches a shell because one call
            // site forgot the flag.
            var descriptor: Int32 = 3
            let limit = getdtablesize()
            while descriptor < limit {
                if descriptor != reportWrite { close(descriptor) }
                descriptor += 1
            }
            // The privilege drop, and the only place in this project that
            // changes a credential. It happens here — in the child, after the
            // descriptor sweep so that nothing root opened survives it, and
            // before both `chdir` and `execve` — because a drop after `execve`
            // is not a drop at all and a drop in the parent would be the daemon
            // giving up its own root.
            //
            // Order is not a style choice. `setuid` is what surrenders the
            // privilege that `setgid` and `setgroups` require, so groups first,
            // then the group, then the user; the reverse order leaves a child
            // running as `mobile` while still in root's group, and nothing
            // afterwards can fix it. `setgroups` rather than `initgroups(3)`
            // for the async-signal-safety reason above: `initgroups` reads the
            // group database.
            if mustDrop {
                // The tty follows the user, the way `login` does it. `forkpty`
                // opened the slave as root, so `grantpt` left it owned by root
                // — and the child would keep it, because descriptors 0, 1 and 2
                // are already open and permissions are only checked at `open`.
                // It matters for everything that reopens its own terminal by
                // name: a pager, an editor, anything that wants `/dev/tty`.
                // Done while still root, and ignored if it fails, because a
                // root-owned tty is a worse session rather than no session.
                _ = fchown(0, dropUID, dropGID)
                var group = dropGID
                if setgroups(1, &group) != 0 || setgid(dropGID) != 0 || setuid(dropUID) != 0 {
                    report.pointee = Darwin.errno
                    writeReport(reportWrite, from: report)
                    _exit(127)
                }
                // And the assertion that the drop was real. `setuid` from a
                // process with euid 0 sets the real, effective *and* saved-set
                // uids, so afterwards there is no root left to return to and
                // this call must fail. If it succeeds, the three calls above
                // all returned 0 and the child is nevertheless still able to
                // become root — a session that is `mobile` in name only. There
                // is no recovering from that, so it never reaches `execve`.
                if setuid(0) == 0 {
                    report.pointee = EPERM
                    writeReport(reportWrite, from: report)
                    _exit(127)
                }
            }
            // After the drop on purpose: `chdir` as root and then dropping
            // would leave the session's cwd inside a directory the session's
            // user cannot open, and relative lookups from a cwd are not
            // rechecked against its ancestors — a small hole, but a real one.
            // A refusal here is not fatal; the child stays in the daemon's own
            // directory, which is launchd's `/`.
            if let directory { _ = chdir(directory) }
            // `SIG_IGN` survives `execve`, and libdispatch leaves SIGPIPE
            // ignored: without this `yes | head` would see EPIPE writes
            // succeed forever instead of the exit a terminal gives it.
            signal(SIGPIPE, SIG_DFL)
            execve(executable, argvPointer, envpPointer)
            report.pointee = Darwin.errno
            writeReport(reportWrite, from: report)
            _exit(127)
        }
        close(reportWrite)
        guard pid > 0, master >= 0 else {
            let failure = FilaFailure(errno: Darwin.errno, path: plan.executable)
            close(reportRead)
            if master >= 0 { close(master) }
            throw failure
        }

        // Blocks only until the child execs (EOF) or gives up (four bytes).
        do {
            defer { close(reportRead) }
            if let error = try readReport(reportRead) {
                throw FilaFailure(code: .operationFailed, systemError: error, path: plan.executable)
            }
            // A later fork must not keep this terminal alive through exec.
            guard fcntl(master, F_SETFD, FD_CLOEXEC) == 0 else {
                throw FilaFailure(errno: Darwin.errno, path: plan.executable)
            }
        } catch {
            // An unreadable or incomplete report is not proof of exec. The
            // child remains ours and waitable until this cleanup reaps it.
            _ = killpg(pid, SIGKILL)
            _ = kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, Darwin.errno == EINTR {}
            close(master)
            throw error
        }

        return TerminalLaunch(
            descriptor: master,
            process: TerminalProcess(processIdentifier: pid),
            executable: plan.executable,
            // Who the child actually is. The parent is entitled to say so
            // without asking: a child that failed any part of the drop wrote an
            // errno down the report pipe and never exec'd, and the throw above
            // is the only way out of that. Nothing here raises privilege, so
            // this is either the daemon's own user or the one it dropped to.
            userIdentifier: plan.credential?.uid ?? getuid()
        )
    }

    /// Empty EOF is the close-on-exec signal. A full report is the child's
    /// errno; a partial report or read error leaves launch unconfirmed.
    static func readReport(_ descriptor: Int32) throws -> Int32? {
        var error: Int32 = 0
        return try withUnsafeMutablePointer(to: &error) { buffer in
            let wanted = MemoryLayout<Int32>.size
            var total = 0
            while total < wanted {
                let got = read(descriptor, UnsafeMutableRawPointer(buffer).advanced(by: total), wanted - total)
                if got > 0 { total += got; continue }
                if got < 0 {
                    if Darwin.errno == EINTR { continue }
                    throw FilaFailure(errno: Darwin.errno)
                }
                guard total == 0 else { throw FilaFailure(errno: EIO) }
                return nil
            }
            guard buffer.pointee > 0 else { throw FilaFailure(errno: EIO) }
            return buffer.pointee
        }
    }

    /// Used after fork: only trivial locals and async-signal-safe write calls.
    private static func writeReport(_ descriptor: Int32, from buffer: UnsafePointer<Int32>) {
        let wanted = MemoryLayout<Int32>.size
        var total = 0
        while total < wanted {
            let sent = Darwin.write(descriptor, UnsafeRawPointer(buffer).advanced(by: total), wanted - total)
            if sent > 0 { total += sent; continue }
            if sent < 0, Darwin.errno == EINTR { continue }
            return
        }
    }
}

/// A NULL-terminated `char *[]`, allocated before a fork and freed after it.
private struct CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ values: [String]) {
        count = values.count
        pointer = .allocate(capacity: values.count + 1)
        for (index, value) in values.enumerated() { pointer[index] = strdup(value) }
        pointer[values.count] = nil
    }

    func deallocate() {
        for index in 0 ..< count { free(pointer[index]) }
        pointer.deallocate()
    }
}

// MARK: - The child, once it is running

/// The spawned process, from the daemon's side: something to reap, and
/// something to hang up.
///
/// This is the daemon's *entire* per-session cost. It holds no descriptor, no
/// buffer and no byte of the stream — the master went to the client and the
/// client pumps it — so a hundred sessions are a hundred pids and a hundred
/// dispatch sources, and a shell printing a gigabyte costs this process
/// nothing. That is what keeps `filad` under launchd's 6 MB jetsam cap without
/// the second process `ighostvtd` needs.
public final class TerminalProcess: @unchecked Sendable {
    public let processIdentifier: pid_t

    private let queue = DispatchQueue(label: "wiki.qaq.fila.terminal", qos: .utility)
    private var exitSource: DispatchSourceProcess?
    private var killTimer: DispatchSourceTimer?
    private var hasExited = false

    /// Called once, on a private queue, when the child has been reaped.
    private var onExit: (@Sendable () -> Void)?

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }

    /// Start watching for the child's exit. Every session must call this, or
    /// the daemon accumulates zombies for as long as the app is connected.
    public func watch(onExit: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard exitSource == nil, !hasExited else { return }
            self.onExit = onExit
            let source = DispatchSource.makeProcessSource(
                identifier: processIdentifier,
                eventMask: .exit,
                queue: queue
            )
            // Even a natural leader exit must finish cleaning its owned group.
            // Keep the zombie waitable until the last signal so its PID cannot
            // be recycled underneath a delayed killpg.
            source.setEventHandler { self.beginTermination() }
            exitSource = source
            source.activate()
            // A child may already have exited before source registration.
            var information = siginfo_t()
            var result: Int32
            repeat {
                result = waitid(P_PID, id_t(processIdentifier), &information, WEXITED | WNOHANG | WNOWAIT)
            } while result < 0 && Darwin.errno == EINTR
            if result == 0, information.si_pid == processIdentifier {
                beginTermination()
            } else if result < 0, Darwin.errno == ECHILD {
                settle()
            }
        }
    }

    /// Hang up the original process group, then force it to stop after grace.
    /// Jobs that created another group or detached session are outside this
    /// group's ownership; this is not a whole-session process supervisor.
    public func terminate() {
        queue.async { [self] in beginTermination() }
    }

    private func beginTermination() {
        guard !hasExited, killTimer == nil else { return }
        _ = killpg(processIdentifier, SIGHUP)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + FilaProtocol.terminalHangupGraceSeconds, repeating: .milliseconds(100))
        // Both sources retain this owner until the direct child is reaped. A
        // leader's early exit cannot cancel the group's forced-kill deadline.
        timer.setEventHandler {
            guard !self.hasExited else { return }
            _ = killpg(self.processIdentifier, SIGKILL)
            self.reapIfExited()
        }
        killTimer = timer
        timer.activate()
    }

    private func reapIfExited() {
        guard !hasExited else { return }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(processIdentifier, &status, WNOHANG)
        } while result < 0 && Darwin.errno == EINTR
        // A still-running child keeps this owner alive. Neither an elapsed
        // retry budget nor an unrelated wait error is evidence of completion.
        guard result == processIdentifier || (result < 0 && Darwin.errno == ECHILD) else { return }
        settle()
    }

    /// Nothing more will be done for this process: drop the sources, and tell
    /// whoever is holding the session that it is over.
    private func settle() {
        guard !hasExited else { return }
        hasExited = true
        exitSource?.cancel()
        exitSource = nil
        killTimer?.cancel()
        killTimer = nil
        let handler = onExit
        onExit = nil
        handler?()
    }
}
