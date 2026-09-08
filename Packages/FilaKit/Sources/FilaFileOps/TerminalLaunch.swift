import Darwin
import CTerminalSession
import Dispatch
import FilaProtocol
import Foundation

/// What a terminal session is asked to run.
///
/// There is deliberately **no `arguments` and no `environment`**. The wire
/// carries a path, a user, a directory and a window size; argv and the initial
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
    /// terminal so its output is the user's to read. The account's supported
    /// login shell loads its environment, then execs `dpkg -i <package>`;
    /// without a supported executable shell, dpkg starts directly. The package
    /// stays a separate argument, never shell source. Refused with `executable`
    /// set, and refused for `.mobile`
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
    /// The canonical target selected for this session, preserving the program
    /// behind a symlink. Launch acknowledges the launcher, not target completion:
    /// account startup files may exit before handing over to this program.
    public let executable: String
    /// The canonical program started by the session holder (possibly a shell).
    public let launcher: String
    /// Who it actually runs as. Sent to the client so the UI can say so rather
    /// than assume it: the app asked for one of two users, and this is the
    /// answer, which is the direction of that sentence that cannot lie. It is
    /// only ever reported after the program was spawned — a drop that
    /// failed never gets this far, because the child refuses to exec and says
    /// so down the report pipe.
    public let userIdentifier: uid_t
}

public extension FileOperations {
    static func runTerminalSessionIfRequested() {
        fila_terminal_session_if_requested(CommandLine.argc, CommandLine.unsafeArgv)
    }

    /// Open a pseudo-terminal and run one program on it, as root or as
    /// `mobile`.
    ///
    /// **What this spawns:** the account's login shell initializes the session
    /// and execs one fixed target: a regular executable with no extra arguments;
    /// the requested script interpreter with that file; or the bootstrap's
    /// `dpkg -i` with one package, as root only. Unknown or unavailable shells
    /// fall back to the target directly. Without a target it opens the shell.
    /// These argv lists are composed here; the client supplies no command source
    /// or flags. **As whom:** whoever `filad` is — root on a device — or the
    /// `mobile` account resolved by name, and nothing else, because the wire
    /// carries a two-case `TerminalUser` and not a uid. **What it refuses:**
    /// client-supplied argv, environment or shell source, a package that is not a
    /// regular file, anything that is not a
    /// real executable regular file, and any climb in privilege — the only
    /// credential change here is downward, it happens in the child before
    /// spawning the program, and the holder checks that it can no longer
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
        let holder = try FilaPath.resolve(layout.resolve(layout.bootstrapPath("/usr/libexec/filad")))
        return try TerminalSpawn.run(plan, sessionHolder: holder, columns: request.columns, rows: request.rows)
    }
}
