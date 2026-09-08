import Darwin
import FilaProtocol
import Foundation

// MARK: - What runs, and in what world

/// Everything the session needs, decided before it is spawned.
struct TerminalPlan {
    /// Real launcher path, for `posix_spawn`. Always `arguments[0]` as well — nothing here
    /// ever runs a program under a name that is not its own.
    var executable: String
    var targetExecutable: String
    var arguments: [String]
    var environment: [String: String]
    /// Already checked to be a directory; nil means the child stays in the
    /// daemon's own, which is launchd's `/`.
    var workingDirectory: String?
    /// **Non-nil only when the child must become someone else.** Nil is not
    /// "run as root" — it is "change nothing", which is the only honest
    /// spelling of a process that never raises privilege. Where this is set,
    /// the holder drops to it before starting the program and verifies it cannot climb back.
    var credential: Credential?

    /// The ids the holder drops to, resolved from the bootstrap passwd database.
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
        var inputIsRootControlled = true

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
            inputIsRootControlled = Self.isRootControlled(resolved)
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
        } else {
            // The empty target means an interactive session below.
            executable = ""
            arguments = []
        }

        targetExecutable = arguments.isEmpty ? "" : try FilaPath.resolve(executable)
        if !arguments.isEmpty {
            executable = targetExecutable
            arguments[0] = targetExecutable
        }
        // A root launch of a mutable program must not spend time in startup
        // files between validation and exec. Preserve the direct-exec path for
        // downloads, including a mutable script behind a trusted interpreter.
        let initializesTarget = getuid() != 0 || credential != nil || request.executable == nil
            || (inputIsRootControlled && Self.isRootControlled(targetExecutable))

        // Every terminal entry point uses the same account environment. Resolve
        // argv first, then let the login shell initialize and exec that target.
        // No PAM login process: pam_launchd can move the child into a bootstrap
        // namespace that cannot reach the system DNS service.
        if let shell = Self.loginShell(user: user, layout: layout) {
            environment["SHELL"] = shell
            let shellPath = try FilaPath.resolve(layout.resolve(shell))
            guard Self.isExecutableFile(shellPath) else {
                throw FilaFailure(code: .notPermitted, systemError: EACCES, path: shellPath)
            }
            if arguments.isEmpty {
                executable = shellPath
                targetExecutable = shellPath
                arguments = [shellPath] + (Self.shellExecArguments(shell) == nil ? [] : ["-il"])
            } else if initializesTarget, let invocation = Self.shellExecArguments(shell) {
                arguments[0] = layout.programPath(executable)
                arguments = [shellPath] + invocation + arguments
                executable = shellPath
            }
        } else if arguments.isEmpty {
            throw FilaFailure(code: .notFound, systemError: ENOENT)
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

    /// Honour the account's shell before trying the bootstrap's defaults.
    /// Account paths already use the bootstrap's vocabulary; an unprefixed
    /// rootless entry is also tried beneath the derived install prefix.
    private static func loginShell(user: PasswdEntry?, layout: BootstrapLayout) -> String? {
        let usable: (String) -> Bool = { candidate in
            guard let resolved = try? FilaPath.resolve(layout.resolve(candidate)) else { return false }
            return Self.isExecutableFile(resolved)
        }
        if let named = user?.shell, named.hasPrefix("/"), !named.utf8.contains(0),
           let shell = [named, layout.bootstrapPath(named)].first(where: usable) {
            return shell
        }
        return bootstrapShells.map(layout.bootstrapPath).first(where: usable)
    }

    /// Fixed source only; the target and its arguments are separate argv entries.
    /// Exec preserves the terminal leader and the target's exit status. A shell
    /// that starts but fails is never retried: the target may have done work.
    private static func shellExecArguments(_ shell: String) -> [String]? {
        switch FilaPath.name(of: shell) {
        case "sh", "dash", "bash", "zsh", "ksh":
            ["-ilc", #"exec "$@""#, "fila-exec"]
        case "fish":
            // Fish has no $0 placeholder; every argument after -c is in $argv.
            ["-ilc", "exec $argv"]
        default:
            nil
        }
    }

    /// Conservative admission for delaying root execution through login setup.
    /// Every component must be root-owned, without group/world writes or ACLs.
    /// An unfamiliar ACL falls back to direct execution, never to guessing its
    /// effective permissions. `path` is canonical before it reaches this check.
    static func isRootControlled(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var component = path
        while true {
            var info = stat()
            guard lstat(component, &info) == 0, info.st_uid == 0,
                  info.st_mode & 0o022 == 0,
                  info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else { return false }
            if let acl = acl_get_file(component, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                if acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0 { return false }
                guard errno == EINVAL else { return false }
            } else if errno != ENOTSUP && errno != ENOENT {
                return false
            }
            if component == "/" { return true }
            component = (component as NSString).deletingLastPathComponent
        }
    }

    /// XNU reads a shebang out of the first page and gives up at 512 bytes, so
    /// there is nothing past that to read and no reason to read further. The
    /// bound is the point: this is the one place the daemon looks inside a file
    /// the user chose, and a file manager's files are gigabytes.
    private static let shebangLimit = 512

    /// The interpreter a script's `#!` line names, or nil when the file does
    /// not begin with one.
    ///
    /// **Only the interpreter, and only when it is the whole line.** A shebang
    /// may carry an argument, and passing it on would be the daemon running a
    /// program with a flag the file chose — the shape `openTerminal` exists to
    /// refuse. Dropping it is no better: `#!/bin/sh -e` says abort at the first
    /// failing command, and a maintenance script that runs to the end instead,
    /// as root, is a worse outcome than one that does not start. So a line with
    /// anything after the interpreter is not redirected at all — nil here means
    /// the file is exec'd as it stands and the kernel reads the line itself,
    /// flags included, which is the only reading that cannot be wrong.
    ///
    /// The single exception is `env`, where the word after it *is* the
    /// interpreter rather than an option; anything else on that line — a flag,
    /// an assignment, a further argument — ends the read, because `env -S` and
    /// `env NAME=value` are both ways of spelling a command line.
    /// Not private so the harness can hand it the file the plan's own stat
    /// would have refused first — a FIFO — which is the whole point of the
    /// non-blocking open below.
    static func shebangInterpreter(of path: String) -> String? {
        // `O_NOFOLLOW` on an already-canonical path: realpath resolved the last
        // component, so this only refuses one that was swapped for a symlink
        // since. `O_NONBLOCK` because this runs on the daemon's control queue:
        // the caller stat'd a regular file, but a FIFO put at that path in the
        // window since would make this `open` wait for a writer and take every
        // file operation in the app down with it. `fstat` then closes the same
        // window for whatever was actually opened — reading is all that happens
        // here, and only a regular file is worth reading.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else { return nil }
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
        guard first.split(separator: "/").last == "env" else {
            return fields.count == 1 ? first : nil
        }
        guard fields.count == 2, let named = fields.last,
              !named.hasPrefix("-"), !named.contains("=") else { return nil }
        return named
    }

    /// Where a program the shebang named actually lives, as a syscall wants it,
    /// or nil when no spelling of it is runnable.
    ///
    /// **The bootstrap's copy is the fallback, not the first answer.** Every
    /// script on every machine is written `#!/bin/sh`, and on a rootless device
    /// that file does not exist — `/var/jb/bin/sh` is the one that does. So the
    /// literal path is tried as written, then the bootstrap's spelling of the
    /// same name, and last the untouched iOS filesystem: under roothide the
    /// first two are the same string and `resolve` puts the jbroot in front of
    /// both, so without `systemPath` an interpreter that lives only outside the
    /// bootstrap — `/usr/bin/perl`, which is what the kernel itself would have
    /// exec'd — is never found, and `#!/usr/bin/perl` would fail where
    /// `#!/usr/bin/env perl` succeeds. A bare word only ever arrives from
    /// `env`, and is looked for in the directories `PATH` names, in the same
    /// order the session's own `PATH` lists them.
    private static func program(named name: String, layout: BootstrapLayout) -> String? {
        if name.hasPrefix("/") {
            for candidate in [name, layout.bootstrapPath(name), layout.systemPath(name)] {
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
        // matters: `posix_spawn` returns `EACCES`, the holder writes it down the report
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
