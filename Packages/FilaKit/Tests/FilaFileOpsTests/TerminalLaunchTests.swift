import Darwin
import Foundation
import Testing
import FilaTestSupport

@testable import FilaFileOps
@testable import FilaProtocol

/// The one place in this project that creates a process, against real
/// pseudo-terminals and real children.
///
/// These run as an ordinary user on the Mac, which is the point: `openTerminal`
/// never raises privileges — the session is whoever the daemon is — so the same
/// code path the device runs as root is exercised here as the developer.
///
/// **The half these cannot reach is the root → `mobile` drop itself.** It only
/// happens when the process is root, these tests are not, and running the
/// harness as root to reach it would mean every other test in this package
/// spent its time able to destroy the machine. So what is covered here is: the
/// branch that decides whether to drop at all, the fact that a session reports
/// the user it actually got, and that the child has no root in it. That the
/// `setgroups`/`setgid`/`setuid` sequence sticks — and that a child which could
/// still call `setuid(0)` refuses to `execve` — is device behaviour, proven on
/// the vphone and nowhere else.
@Suite("Terminal")
struct TerminalLaunchTests {
    private let account = Scratch()

    init() {
        account.directory("etc")
        account.file("etc/passwd", contents: "tester:*:\(getuid()):\(getgid()):Tester:\(account.root):/bin/sh\n")
    }

    /// Isolate startup files from the developer's login configuration while
    /// exercising the same plan and real PTY spawn used by FileOperations.
    private func openTerminal(_ request: TerminalRequest) throws -> TerminalLaunch {
        let plan = try TerminalPlan(request: request, layout: BootstrapLayout(kind: .rootless(prefix: account.root)))
        return try TerminalSpawn.run(plan, sessionHolder: TerminalSessionFixture.executable, columns: request.columns, rows: request.rows)
    }

    @Test("launch confirmation distinguishes EOF, errno, and damaged reports")
    func launchReports() throws {
        var failure: Int32 = ENOEXEC
        let full = withUnsafeBytes(of: &failure) { Data($0) }
        for payload in [Data(), Data(repeating: 0, count: 4), full, Data(full.prefix(2))] {
            var descriptors: [Int32] = [-1, -1]
            try #require(pipe(&descriptors) == 0)
            defer { close(descriptors[0]) }
            let sent = payload.withUnsafeBytes { Darwin.write(descriptors[1], $0.baseAddress, $0.count) }
            close(descriptors[1])
            try #require(sent == payload.count)
            switch payload.count {
            case 4: #expect(try TerminalSpawn.readReport(descriptors[0]) == (payload == full ? ENOEXEC : nil))
            default: #expect(throws: FilaFailure.self) { try TerminalSpawn.readReport(descriptors[0]) }
            }
        }
        let unreadable = #expect(throws: FilaFailure.self) { try TerminalSpawn.readReport(-1) }
        #expect(unreadable?.systemError == EBADF)
    }

    @Test("Login initialization admits root-controlled targets and rejects user-writable paths")
    func rootControlledTargets() throws {
        #expect(TerminalPlan.isRootControlled("/bin/echo"))
        let scratch = Scratch()
        let executable = scratch.file("program", mode: 0o700)
        #expect(!TerminalPlan.isRootControlled(executable))
        #expect(!TerminalPlan.isRootControlled(scratch.root + "/missing"))
        #expect(!TerminalPlan.isRootControlled("relative"))
    }

    @Test("An account shell symlink is canonicalized before launch")
    func canonicalShell() throws {
        let scratch = Scratch()
        scratch.directory("etc")
        let shell = scratch.link("sh", to: "/bin/sh")
        scratch.file("etc/passwd", contents: "tester:*:\(getuid()):\(getgid()):Tester:/:\(shell)\n")
        let plan = try TerminalPlan(request: TerminalRequest(), layout: BootstrapLayout(kind: .rootless(prefix: scratch.root)))
        #expect(plan.executable == "/bin/sh")
        #expect(plan.targetExecutable == "/bin/sh")
    }

    @Test("a child reports an executable format refusal instead of a successful launch")
    func reportsExecFailure() throws {
        let scratch = Scratch()
        let file = scratch.file("invalid-program", contents: "Fila format fixture\n", mode: 0o700)
        let failure = #expect(throws: FilaFailure.self) {
            let plan = try TerminalPlan(request: TerminalRequest(executable: file), layout: BootstrapLayout(kind: .roothide(jbroot: scratch.root)))
            return try TerminalSpawn.run(plan, sessionHolder: TerminalSessionFixture.executable, columns: 80, rows: 24)
        }
        #expect(failure?.systemError == ENOEXEC)
    }

    /// Reads until the child's output shows up or the deadline passes. The pump
    /// lives in the app in production; this is the smallest stand-in for it.
    private func readUntil(_ descriptor: Int32, contains needle: String, seconds: Double = 5) -> String {
        var collected = ""
        let deadline = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let got = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, 4096) }
            if got > 0 {
                collected += String(decoding: buffer[0 ..< got], as: UTF8.self)
                if collected.contains(needle) { return collected }
                continue
            }
            if got < 0, errno == EINTR || errno == EAGAIN { continue }
            break
        }
        return collected
    }

    @Test("a program runs, and a child that exits at once is still reaped")
    func runsAProgram() throws {
        // Through a symlink, because that is how a user reaches most things on
        // a jailbroken filesystem and the daemon reports what it actually ran.
        let scratch = Scratch()
        let link = scratch.link("echo", to: "/bin/echo")
        let launch = try openTerminal(TerminalRequest(executable: link))
        defer { close(launch.descriptor) }
        #expect(launch.executable == "/bin/echo")
        #expect(launch.launcher == "/bin/sh")
        #expect(launch.userIdentifier == getuid())
        let ended = DispatchSemaphore(value: 0)
        launch.process.watch { ended.signal() }
        // The app always pumps the PTY. A login shell can leave terminal output
        // waiting to drain, so waiting for exit without reading can block it.
        let output = readUntil(launch.descriptor, contains: "\n")
        #expect(!output.isEmpty)
        #expect(ended.wait(timeout: .now() + 10) == .success)
    }

    @Test("the daemon's own environment reaches the program, and the client's does not")
    func composesTheEnvironment() throws {
        // `sh` reading from the terminal is how the environment is inspected
        // without a way to pass arguments — which is the point being tested:
        // there is no arguments field on the request, so a caller cannot ask
        // for `sh -c`.
        let launch = try openTerminal(TerminalRequest(executable: "/bin/sh"))
        defer { close(launch.descriptor) }
        let script = "printf 'TERM=%s PATH_HEAD=%s\\n' \"$TERM\" \"$PATH\"\n"
        _ = script.withCString { write(launch.descriptor, $0, strlen($0)) }
        let output = readUntil(launch.descriptor, contains: "TERM=xterm-256color")
        #expect(output.contains("TERM=xterm-256color"))
        #expect(output.contains("/usr/local/sbin"))
        launch.process.terminate()
    }

    @Test("a window-size change reaches the program")
    func resizes() throws {
        let launch = try openTerminal(TerminalRequest(executable: "/bin/sh", columns: 80, rows: 24))
        defer { close(launch.descriptor) }
        var size = winsize(ws_row: 40, ws_col: 132, ws_xpixel: 0, ws_ypixel: 0)
        #expect(ioctl(launch.descriptor, TIOCSWINSZ, &size) == 0)
        let script = "stty size\n"
        _ = script.withCString { write(launch.descriptor, $0, strlen($0)) }
        #expect(readUntil(launch.descriptor, contains: "40 132").contains("40 132"))
        launch.process.terminate()
    }

    @Test("nothing that is not an executable regular file starts")
    func refusesWhatIsNotAProgram() throws {
        let scratch = Scratch()
        let text = scratch.file("notes.txt", contents: "hello", mode: 0o644)

        #expect(throws: FilaFailure.self) {
            _ = try openTerminal(TerminalRequest(executable: text))
        }
        #expect(throws: FilaFailure.self) {
            _ = try openTerminal(TerminalRequest(executable: scratch.root))
        }
        #expect(throws: FilaFailure.self) {
            _ = try openTerminal(TerminalRequest(executable: scratch.path("absent")))
        }
        // A relative path never names a node from a root daemon's point of view.
        #expect(throws: FilaFailure.self) {
            _ = try openTerminal(TerminalRequest(executable: "sh"))
        }
    }

    @Test("terminate ends a program that would otherwise sit there forever")
    func terminates() throws {
        let launch = try openTerminal(TerminalRequest(executable: "/bin/cat"))
        defer { close(launch.descriptor) }
        let pid = launch.process.processIdentifier
        #expect(kill(pid, 0) == 0)

        let ended = DispatchSemaphore(value: 0)
        launch.process.watch { ended.signal() }
        launch.process.terminate()
        #expect(ended.wait(timeout: .now() + 10) == .success)
        // Reaped, not merely signalled: a daemon that only killed would collect
        // a zombie per session for as long as the app stayed connected.
        #expect(kill(pid, 0) != 0)
    }

    @Test("The controlling terminal handles interruption and does not inherit daemon descriptors")
    func controllingTerminal() throws {
        let scratch = Scratch()
        let original = Darwin.open(scratch.file("private"), O_RDONLY)
        try #require(original >= 0)
        defer { close(original) }
        let privateDescriptor = fcntl(original, F_DUPFD, 100)
        try #require(privateDescriptor >= 100)
        defer { close(privateDescriptor) }
        let launch = try openTerminal(TerminalRequest())
        let ended = DispatchSemaphore(value: 0)
        launch.process.watch { ended.signal() }
        defer {
            close(launch.descriptor)
            launch.process.terminate()
            #expect(ended.wait(timeout: .now() + 10) == .success)
        }
        var attributes = termios()
        try #require(tcgetattr(launch.descriptor, &attributes) == 0)
        attributes.c_lflag &= ~tcflag_t(ECHO)
        try #require(tcsetattr(launch.descriptor, TCSANOW, &attributes) == 0)
        func send(_ text: String) {
            _ = text.withCString { write(launch.descriptor, $0, strlen($0)) }
        }
        send("test ! -e /dev/fd/\(privateDescriptor) && printf 'CLOSED\\n'; stty size </dev/tty; printf 'READY\\n'\n")
        let output = readUntil(launch.descriptor, contains: "READY")
        #expect(output.contains("CLOSED"))
        #expect(output.contains("24 80"))
        send("sleep 30\n")
        usleep(200_000)
        send("\u{03}")
        send("printf 'INTERRUPTED\\n'\n")
        #expect(readUntil(launch.descriptor, contains: "INTERRUPTED").contains("INTERRUPTED"))
    }

    @Test("cleanup waits for the kill grace when the leader exits before its child")
    func cleansUpAfterLeaderExits() throws {
        let launch = try openTerminal(TerminalRequest(executable: "/bin/sh"))
        let holder = launch.process.processIdentifier
        let ended = DispatchGroup()
        ended.enter()
        launch.process.watch { ended.leave() }
        defer {
            close(launch.descriptor)
            launch.process.terminate()
            #expect(ended.wait(timeout: .now() + 10) == .success)
        }
        var attributes = termios()
        try #require(tcgetattr(launch.descriptor, &attributes) == 0)
        attributes.c_lflag &= ~tcflag_t(ECHO)
        try #require(tcsetattr(launch.descriptor, TCSANOW, &attributes) == 0)
        try #require(fcntl(launch.descriptor, F_SETFL, O_NONBLOCK) == 0)
        // Both ignore HUP. Once ready, this fixture ends the leader itself,
        // leaving a known live child in the original group until forced kill.
        let script = "set +H\nset +m; trap '' HUP; /bin/sleep 30 & child=$!; printf '\\nCHILD=%s\\n' \"$child\"; printf 'LEADER=%s\\n' \"$$\"; printf 'READY\\n'; wait\n"
        let written = script.withCString { write(launch.descriptor, $0, strlen($0)) }
        try #require(written == script.utf8.count)
        let output = readUntil(launch.descriptor, contains: "READY")
        let childLine = try #require(output.components(separatedBy: .newlines).first { $0.hasPrefix("CHILD=") }, "Controlled shell output: \(output)")
        let child = try #require(pid_t(childLine.dropFirst(6)))
        let leaderLine = try #require(output.components(separatedBy: .newlines).first { $0.hasPrefix("LEADER=") })
        let leader = try #require(pid_t(leaderLine.dropFirst(7)))
        try #require(child > 0 && getpgid(child) == leader)

        try #require(kill(leader, SIGKILL) == 0)
        try #require(ended.wait(timeout: .now() + 0.25) == .timedOut)
        #expect(kill(child, 0) == 0)
        #expect(ended.wait(timeout: .now() + 10) == .success)
        #expect(kill(leader, 0) != 0)
        #expect(kill(holder, 0) != 0)
        let deadline = Date().addingTimeInterval(5)
        while kill(child, 0) == 0, Date() < deadline { usleep(10_000) }
        #expect(kill(child, 0) != 0)
    }

    @Test("a session reports the user it got, and the child is that user with no root in it")
    func runsAsTheUserItReports() throws {
        for user in TerminalUser.allCases {
            let launch = try openTerminal(TerminalRequest(executable: "/bin/sh", user: user))
            defer { close(launch.descriptor) }
            // Not root, so `.mobile` has nothing to drop and both cases resolve
            // to this process's own user. On a device these differ; here the
            // assertion that matters is that the answer is measured rather than
            // assumed — the daemon reports a uid and the child agrees with it.
            #expect(launch.userIdentifier == getuid())

            // Real *and* effective, from inside the child: a drop that moved
            // only the effective uid would leave the real one root, and the
            // process could walk it back with one call.
            let script = "printf 'RUID=%s EUID=%s\\n' \"$(id -ru)\" \"$(id -u)\"\n"
            _ = script.withCString { write(launch.descriptor, $0, strlen($0)) }
            let expected = "RUID=\(getuid()) EUID=\(getuid())"
            #expect(readUntil(launch.descriptor, contains: expected).contains(expected))
            #expect(getuid() != 0, "a root harness would make the line above vacuous")
            launch.process.terminate()
        }
    }

    @Test("nothing is dropped when there is nothing to drop")
    func dropsOnlyFromRoot() throws {
        // The credential is the flag that makes the child change identity, and
        // it is set from exactly one place. Off-device it must stay nil for
        // both users, because a `setuid` from an unprivileged process fails and
        // a child that tried would die instead of opening a terminal.
        let layout = BootstrapLayout(installRoot: "")
        for user in TerminalUser.allCases {
            let plan = try TerminalPlan(request: TerminalRequest(user: user), layout: layout)
            #expect(plan.credential == nil)
        }
    }

    @Test("the account shell wins, with a bootstrap fallback for missing shells")
    func prefersTheAccountShell() throws {
        let scratch = Scratch()
        scratch.directory("usr/libexec")
        scratch.directory("bin")
        scratch.directory("etc")
        scratch.file("bin/zsh", contents: "#!/bin/sh\n", mode: 0o755)
        scratch.file("bin/fish", contents: "#!/bin/sh\n", mode: 0o755)
        scratch.file("etc/passwd", contents: "tester:*:\(getuid()):\(getgid()):Tester:/:/bin/fish\n")
        let layout = BootstrapLayout(installRoot: scratch.root)
        let plan = try TerminalPlan(request: TerminalRequest(), layout: layout)
        #expect(plan.executable == scratch.path("bin/fish"))
        #expect(plan.environment["SHELL"] == "/bin/fish")
        #expect(plan.arguments == [scratch.path("bin/fish"), "-il"])

        scratch.file("etc/passwd", contents: "tester:*:\(getuid()):\(getgid()):Tester:/:/missing\n")
        let fallback = try TerminalPlan(request: TerminalRequest(), layout: layout)
        #expect(fallback.executable == scratch.path("bin/zsh"))
    }

    /// The bug this exists for: every script on every machine is written
    /// `#!/bin/sh`, and a rootless device has no `/bin/sh` — the bootstrap's is
    /// at `/var/jb/bin/sh`. Without the redirect `execve` answers `ENOENT` and
    /// the script simply does not run.
    @Test("a script runs through the bootstrap's copy of the interpreter it names")
    func redirectsAScriptInterpreter() throws {
        let bootstrap = Scratch()
        bootstrap.directory("bin")
        bootstrap.directory("usr/bin")
        // Named somewhere that does not exist on this machine either, so that
        // the literal spelling cannot be what answers.
        let shell = bootstrap.file("bin/absent-sh", contents: "#!/bin/sh\n", mode: 0o755)
        let layout = BootstrapLayout(kind: .rootless(prefix: bootstrap.root))

        let scripts = Scratch()
        let script = try FilaPath.resolve(
            scripts.file("job.sh", contents: "#!/bin/absent-sh\necho hi\n", mode: 0o755)
        )
        let plan = try TerminalPlan(
            request: TerminalRequest(executable: script, redirectsScriptInterpreter: true),
            layout: layout
        )
        #expect(Array(plan.arguments.suffix(2)) == [shell, script])

        // Off, the file is exec'd as it stands — which is what it was before
        // the setting, and what the kernel then refuses.
        let literal = try TerminalPlan(request: TerminalRequest(executable: script), layout: layout)
        #expect(literal.arguments.last == script)
    }

    @Test("a shebang that carries an argument is left to the kernel, not rewritten")
    func ignoresShebangArguments() throws {
        let bootstrap = Scratch()
        bootstrap.directory("usr/bin")
        let bash = bootstrap.file("usr/bin/absent-bash", contents: "#!/bin/sh\n", mode: 0o755)
        let layout = BootstrapLayout(kind: .rootless(prefix: bootstrap.root))
        let scripts = Scratch()

        // Honouring the flag would be the daemon running a program with a
        // command line the file wrote; dropping it would run `#!/bin/sh -e`
        // without its abort-on-failure, as root, while the file says otherwise.
        // So the redirect stands aside and the file is exec'd as it is.
        let flagged = try FilaPath.resolve(
            scripts.file("flagged.sh", contents: "#!/usr/bin/absent-bash -x\n", mode: 0o755)
        )
        let plan = try TerminalPlan(
            request: TerminalRequest(executable: flagged, redirectsScriptInterpreter: true),
            layout: layout
        )
        #expect(plan.arguments.last == flagged)

        // `env` is not the interpreter, it is how a script says "look on PATH"
        // — and it is itself missing on a rootless device, which is why the
        // word after it has to be resolved here rather than by exec'ing env.
        let viaEnv = try FilaPath.resolve(
            scripts.file("env.sh", contents: "#!/usr/bin/env absent-bash\n", mode: 0o755)
        )
        let resolvedByName = try TerminalPlan(
            request: TerminalRequest(executable: viaEnv, redirectsScriptInterpreter: true),
            layout: layout
        )
        #expect(Array(resolvedByName.arguments.suffix(2)) == [bash, viaEnv])

        // `env -S`, `env NAME=value` and an argument after the interpreter are
        // all ways of spelling a command line, so none of them names an
        // interpreter this daemon will look up.
        for line in [
            "#!/usr/bin/env -S absent-bash -x\n",
            "#!/usr/bin/env NAME=value absent-bash\n",
            "#!/usr/bin/env absent-bash -x\n",
        ] {
            let path = try FilaPath.resolve(scripts.file("spelled.sh", contents: line, mode: 0o755))
            let unredirected = try TerminalPlan(
                request: TerminalRequest(executable: path, redirectsScriptInterpreter: true),
                layout: layout
            )
            #expect(unredirected.arguments.last == path)
        }
    }

    @Test("an interpreter the jbroot does not ship is still found on the system filesystem")
    func findsASystemInterpreterUnderRoothide() throws {
        // roothide's own spelling of a bootstrap file is the file's plain name,
        // and `resolve` puts the jbroot in front of it — so the literal and the
        // bootstrap candidates are one string, and only `systemPath` reaches
        // the untouched filesystem, bridged in at `/rootfs`. Without it a
        // script naming an interpreter that exists only there — which is what
        // the kernel itself would have exec'd — would be refused as missing.
        let jbroot = Scratch()
        jbroot.directory("usr/libexec")
        jbroot.directory("rootfs/usr/bin")
        let system = jbroot.file("rootfs/usr/bin/absent-perl", contents: "#!/bin/sh\n", mode: 0o755)
        let layout = BootstrapLayout(installRoot: jbroot.root)

        let scripts = Scratch()
        let script = try FilaPath.resolve(
            scripts.file("job.pl", contents: "#!/usr/bin/absent-perl\n", mode: 0o755)
        )
        let plan = try TerminalPlan(
            request: TerminalRequest(executable: script, redirectsScriptInterpreter: true),
            layout: layout
        )
        #expect(plan.executable == system)
        #expect(plan.arguments == [system, layout.systemPath(script)])
    }

    @Test(
        "the shebang read refuses a fifo instead of waiting for a writer",
        .timeLimit(.minutes(1))
    )
    func refusesToReadAFifo() throws {
        // The shebang read is the one place the daemon opens a file the user
        // chose, and it runs on the control queue. The plan stats the file
        // first, so a FIFO never gets that far — but a FIFO put at that path in
        // the window between the stat and the open would block `open` until a
        // writer appeared, with every file operation in the app behind it. Hand
        // the read the FIFO directly, which is that window: it must come back,
        // and it must come back with nothing. Without `O_NONBLOCK` this test
        // does not fail, it hangs — hence the limit.
        let scratch = Scratch()
        let fifo = scratch.root + "/pipe"
        try #require(mkfifo(fifo, 0o755) == 0)
        #expect(TerminalPlan.shebangInterpreter(of: fifo) == nil)

        // And the outer refusal, which is what a client actually meets: a FIFO
        // is not a program, whatever it would say if it were read.
        let failure = #expect(throws: FilaFailure.self) {
            try TerminalPlan(
                request: TerminalRequest(executable: fifo, redirectsScriptInterpreter: true),
                layout: BootstrapLayout(installRoot: "")
            )
        }
        #expect(failure?.systemError == EACCES)
    }

    @Test("a shebang naming an interpreter that is nowhere says which one")
    func reportsAMissingInterpreter() throws {
        let scripts = Scratch()
        let script = scripts.file("job.sh", contents: "#!/usr/bin/absent-python\n", mode: 0o755)
        let failure = #expect(throws: FilaFailure.self) {
            try TerminalPlan(
                request: TerminalRequest(executable: script, redirectsScriptInterpreter: true),
                layout: BootstrapLayout(installRoot: "")
            )
        }
        // The interpreter, not the script: the script is the one file here that
        // does exist, and naming it would send the user looking at the wrong
        // thing.
        #expect(failure?.path == "/usr/bin/absent-python")
        #expect(failure?.systemError == ENOENT)
    }

    @Test("a program with no shebang is still exec'd as itself")
    func leavesBinariesAlone() throws {
        // The redirect reads a first line; a Mach-O has none, and turning the
        // setting on must not put an interpreter in front of every binary.
        let plan = try TerminalPlan(
            request: TerminalRequest(executable: "/bin/echo", redirectsScriptInterpreter: true),
            layout: BootstrapLayout(installRoot: "")
        )
        #expect(plan.arguments.last == "/bin/echo")
    }

    @Test("the bootstrap vocabulary keeps the two spellings apart")
    func bootstrapSpellings() {
        let rootful = BootstrapLayout(installRoot: "")
        #expect(rootful.bootstrapPath("/bin/zsh") == "/bin/zsh")
        #expect(rootful.systemPath("/usr/bin") == "/usr/bin")
        #expect(rootful.resolve("/bin/zsh") == "/bin/zsh")

        // roothide: its programs are vroot-linked, so paths in the environment
        // stay unprefixed and iOS's own filesystem is bridged in at `/rootfs`;
        // only `execve` gets the jbroot in front. A jbroot is recognised by the
        // daemon's own install directory being in it.
        let scratch = Scratch()
        scratch.directory("usr/libexec")
        let roothide = BootstrapLayout(installRoot: scratch.root)
        #expect(roothide.bootstrapPath("/bin/zsh") == "/bin/zsh")
        #expect(roothide.systemPath("/usr/bin") == "/rootfs/usr/bin")
        #expect(roothide.resolve("/bin/zsh") == scratch.root + "/bin/zsh")

        // A prefix with no bootstrap under it is nobody's jbroot — an app
        // bundle, say. Treating it as one would build every session path
        // against a directory that holds no shell.
        let notABootstrap = BootstrapLayout(installRoot: Scratch().root)
        #expect(notABootstrap.resolve("/bin/zsh") == "/bin/zsh")
        #expect(notABootstrap.systemPath("/usr/bin") == "/usr/bin")
    }

    @Test("a package falls back to direct dpkg when the account has no supported runnable shell")
    func installsAPackage() throws {
        // A jbroot with a dpkg in it, and a package outside it — the common
        // case, a download in `/var/mobile`. The kernel gets the jbroot
        // spelling of dpkg; dpkg, being vroot-linked there, gets the `/rootfs`
        // spelling of the package.
        let scratch = Scratch()
        scratch.directory("usr/libexec")
        scratch.directory("usr/bin")
        scratch.file("usr/bin/dpkg", contents: "#!/bin/sh\n", mode: 0o755)
        let outside = Scratch()
        let package = try FilaPath.resolve(outside.file("fila.deb"))
        let layout = BootstrapLayout(installRoot: scratch.root)

        let plan = try TerminalPlan(request: TerminalRequest(package: package), layout: layout)
        #expect(plan.executable == scratch.root + "/usr/bin/dpkg")
        #expect(plan.arguments == [scratch.root + "/usr/bin/dpkg", "-i", "/rootfs" + package])
        #expect(plan.credential == nil)

        scratch.directory("etc")
        scratch.directory("bin")
        scratch.file("bin/unknown-shell", contents: "#!/bin/sh\n", mode: 0o755)
        for shell in ["", "/bin/zsh", "/bin/unknown-shell", "/bin/zsh\0ignored"] {
            scratch.file("etc/passwd", contents: "tester:*:\(getuid()):\(getgid()):Tester:/:\(shell)\n")
            let fallback = try TerminalPlan(request: TerminalRequest(package: package), layout: layout)
            #expect(fallback.executable == plan.executable)
            #expect(fallback.arguments == plan.arguments)
        }

        // Refused: as mobile, alongside a program, on a directory, and without
        // a dpkg to run. Each is a shape the wire could carry and the plan
        // must not spell.
        #expect(throws: FilaFailure.self) {
            try TerminalPlan(request: TerminalRequest(package: package, user: .mobile), layout: layout)
        }
        #expect(throws: FilaFailure.self) {
            try TerminalPlan(request: TerminalRequest(executable: "/bin/echo", package: package), layout: layout)
        }
        #expect(throws: FilaFailure.self) {
            try TerminalPlan(request: TerminalRequest(package: outside.root), layout: layout)
        }
        #expect(throws: FilaFailure.self) {
            try TerminalPlan(request: TerminalRequest(package: package), layout: BootstrapLayout(installRoot: Scratch().root))
        }
    }

    @Test("package startup keeps kernel and bootstrap path spellings separate", arguments: ["zsh", "fish"])
    func packageShellPaths(shell: String) throws {
        let bootstrap = Scratch()
        bootstrap.directory("usr/libexec")
        bootstrap.directory("usr/bin")
        bootstrap.directory("etc")
        bootstrap.file("usr/bin/dpkg", contents: "#!/bin/sh\n", mode: 0o755)
        bootstrap.file("usr/bin/\(shell)", contents: "#!/bin/sh\n", mode: 0o755)
        bootstrap.file("etc/passwd", contents: "tester:*:\(getuid()):\(getgid()):Tester:/:/usr/bin/\(shell)\n")
        let outside = Scratch()
        let package = outside.file("package.deb")
        let layout = BootstrapLayout(kind: .roothide(jbroot: bootstrap.root))
        let plan = try TerminalPlan(request: TerminalRequest(package: package), layout: layout)
        #expect(plan.executable == bootstrap.path("usr/bin/\(shell)"))
        #expect(plan.environment["SHELL"] == "/usr/bin/\(shell)")
        #expect(Array(plan.arguments.suffix(3)) == ["/usr/bin/dpkg", "-i", "/rootfs" + package])

        let inside = bootstrap.file("usr/bin/tool", contents: "#!/bin/sh\n", mode: 0o755)
        let external = outside.file("tool", contents: "#!/bin/sh\n", mode: 0o755)
        for target in [inside, external] {
            let execution = try TerminalPlan(request: TerminalRequest(executable: target), layout: layout)
            #expect(execution.arguments.last == (target == inside ? "/usr/bin/tool" : "/rootfs" + external))
        }
    }

    @Test("all execution modes load account startup files and preserve literal arguments", arguments: [
        "/bin/sh", "/bin/dash", "/bin/bash", "/bin/zsh", "/bin/ksh",
    ])
    func loginEnvironment(shell: String) throws {
        try checkLoginEnvironment(shell: shell)
    }

    @Test("fish execution uses its argv convention", .enabled(if: TerminalPlan.isExecutableFile("/opt/homebrew/bin/fish")))
    func fishLoginEnvironment() throws {
        try checkLoginEnvironment(shell: "/opt/homebrew/bin/fish")
    }

    @Test("a failed shell startup does not retry installation directly")
    func failedPackageShellStartup() throws {
        let bootstrap = Scratch()
        bootstrap.directory("etc")
        bootstrap.directory("usr/bin")
        let home = bootstrap.directory("home")
        bootstrap.file("etc/passwd", contents: "tester:*:\(getuid()):\(getgid()):Tester:\(home):/bin/zsh\n")
        bootstrap.file("home/.zshenv", contents: "printf 'STARTUP_STOPPED\\n'\nexit 23\n")
        bootstrap.file("usr/bin/dpkg", contents: "#!/bin/sh\nprintf 'INSTALL_STARTED\\n'\n", mode: 0o755)
        let package = bootstrap.file("package.deb")
        let plan = try TerminalPlan(request: TerminalRequest(package: package), layout: BootstrapLayout(kind: .rootless(prefix: bootstrap.root)))
        let launch = try TerminalSpawn.run(plan, sessionHolder: TerminalSessionFixture.executable, columns: 80, rows: 24)
        defer { close(launch.descriptor); launch.process.terminate() }
        let output = readUntil(launch.descriptor, contains: "INSTALL_STARTED")
        #expect(output.contains("STARTUP_STOPPED"))
        #expect(!output.contains("INSTALL_STARTED"))
    }

    private func checkLoginEnvironment(shell: String) throws {
        let bootstrap = Scratch()
        bootstrap.directory("etc")
        bootstrap.directory("usr/bin")
        let home = bootstrap.directory("home")
        bootstrap.directory("home/.config/fish")
        bootstrap.file("etc/passwd", contents: "tester:*:\(getuid()):\(getgid()):Tester:\(home):\(shell)\n")
        // A different default shell is present; installation must follow passwd.
        bootstrap.link("usr/bin/zsh", to: "/bin/zsh")
        bootstrap.file("home/.profile", contents: "export FILA_INIT_PID=$$\nexport FILA_INSTALL_TEST=login\ncase $- in *i*) FILA_INSTALL_TEST=login-interactive;; esac\n")
        bootstrap.file("home/.bash_profile", contents: ". \"$HOME/.profile\"\n")
        bootstrap.file("home/.zprofile", contents: "export FILA_INIT_PID=$$\nexport FILA_INSTALL_TEST=login\n")
        bootstrap.file("home/.zshrc", contents: "export FILA_INSTALL_TEST=$FILA_INSTALL_TEST-interactive\n")
        bootstrap.file("home/.config/fish/config.fish", contents: "set -gx FILA_INIT_PID $fish_pid\nif status is-login; and status is-interactive\n set -gx FILA_INSTALL_TEST login-interactive\nend\n")
        let body = #"""
        #!/bin/sh
        printf 'ARGC=%s\nFLAG=%s\nFILE=%s\nMARK=%s\nSHELL=%s\nPID=%s\nDONE\n' "$#" "$1" "$2" "$FILA_INSTALL_TEST" "$SHELL" "$([ "$FILA_INIT_PID" = "$$" ] && printf unchanged)"
        """#
        bootstrap.file("usr/bin/dpkg", contents: body, mode: 0o755)
        let package = bootstrap.file("雪 ' \" $HOME;[1]*\n.deb")
        let script = bootstrap.file("雪 ' \" $HOME;[1]*\n.sh", contents: body, mode: 0o755)
        let requests = [
            TerminalRequest(package: package),
            TerminalRequest(executable: script),
            TerminalRequest(executable: script, redirectsScriptInterpreter: true),
            TerminalRequest(executable: "/usr/bin/env"),
        ]
        for request in requests {
            let plan = try TerminalPlan(request: request, layout: BootstrapLayout(kind: .rootless(prefix: bootstrap.root)))
            let launch = try TerminalSpawn.run(plan, sessionHolder: TerminalSessionFixture.executable, columns: 120, rows: 24)
            defer { close(launch.descriptor); launch.process.terminate() }
            let binary = request.executable == "/usr/bin/env"
            let output = readUntil(launch.descriptor, contains: binary ? "FILA_INSTALL_TEST=login-interactive" : "DONE")
                .replacingOccurrences(of: "\r\n", with: "\n")
            if binary {
                #expect(output.contains("FILA_INSTALL_TEST=login-interactive"), "\(output)")
            } else {
                let arguments = request.package == nil ? "ARGC=0\nFLAG=\nFILE=\n" : "ARGC=2\nFLAG=-i\nFILE=\(package)\n"
                #expect(output.contains(arguments + "MARK=login-interactive\nSHELL=\(shell)\nPID=unchanged\nDONE"), "\(output)")
            }
        }
    }
}
