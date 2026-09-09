import FilaProtocol
import Foundation

/// A terminal number scoped to the connection that opened it. A reconnect
/// must not turn an old close request into a request for a new process.
public struct TerminalIdentifier: Sendable {
    public let value: UInt64
    /// Older daemons have no owner field; they cannot confirm completion.
    public let owner: String?

    public init(value: UInt64, owner: String?) {
        self.value = value
        self.owner = owner
    }
}

/// A pseudo-terminal with a program already running on it.
public struct Terminal: Sendable {
    public let identifier: TerminalIdentifier
    /// The pseudo-terminal master. **The caller owns it and must `close(2)`
    /// it.** Everything the program prints and everything the user types
    /// travels through this descriptor between the app and the kernel; the
    /// daemon kept no copy and sees none of it.
    public let descriptor: Int32
    /// The resolved session target; account startup may exit before running it.
    public let executable: String
    /// Who it runs as — the daemon's answer, not the request. Zero for a
    /// root session; `mobile`'s uid for one the daemon dropped. The UI
    /// reads this rather than assuming, because telling someone a shell is
    /// root when it is not, or that it is not when it is, are both mistakes
    /// nobody can see until it is too late.
    public let userIdentifier: UInt32

    public init(identifier: TerminalIdentifier, descriptor: Int32, executable: String, userIdentifier: UInt32) {
        self.identifier = identifier
        self.descriptor = descriptor
        self.executable = executable
        self.userIdentifier = userIdentifier
    }

    public var isRoot: Bool {
        userIdentifier == 0
    }
}

/// Opening a program on a pseudo-terminal. Only `filad` can do this — a
/// session spawned in this process would run a shell as whoever the app is,
/// which is not what a root file manager's terminal is for — so the only
/// implementation lives in the privileged module, and a build without that
/// module has no terminal at all rather than a pretend one.
public protocol TerminalAccess: AnyObject, Sendable {
    /// Open a terminal on `executable`, on `dpkg -i package` (root only), or
    /// on the login shell the daemon picks when both are nil, as one of the
    /// two users `TerminalUser` names.
    ///
    /// There is deliberately no way to pass arguments or an environment: the
    /// daemon composes both. `user` is not a uid and cannot be made into one
    /// — see `TerminalUser`. See `FilaOperation.openTerminal`.
    func openTerminal(
        executable: String?,
        package: String?,
        user: TerminalUser,
        redirectsScriptInterpreter: Bool,
        workingDirectory: String?,
        columns: UInt16,
        rows: UInt16
    ) async throws -> Terminal

    /// Hang a terminal up. Closing the master is what the tty layer notices;
    /// this is what makes sure of a program that ignored the `SIGHUP` it
    /// sent. Returns true only when the daemon no longer owns the direct
    /// child. False is a termination request, not proof that input can be
    /// removed.
    @discardableResult
    func closeTerminal(_ identifier: TerminalIdentifier) async throws -> Bool

    /// Drop the connection so the next request builds a new one.
    func invalidate()
}

public extension TerminalAccess {
    func openTerminal(
        executable: String? = nil,
        package: String? = nil,
        user: TerminalUser,
        redirectsScriptInterpreter: Bool = false,
        workingDirectory: String? = nil,
        columns: UInt16,
        rows: UInt16
    ) async throws -> Terminal {
        try await openTerminal(
            executable: executable,
            package: package,
            user: user,
            redirectsScriptInterpreter: redirectsScriptInterpreter,
            workingDirectory: workingDirectory,
            columns: columns,
            rows: rows
        )
    }
}

/// What the privileged module registers: one object that is both the local
/// file layer — choosing the daemon or in-process at the handshake — and the
/// only way to open a terminal. Resolved by the local module to build the
/// full-filesystem backend, and by the app for the terminal; a build that
/// bundles no privileged module resolves nothing here.
public protocol PrivilegedFileAccess: LocalFileAccess, TerminalAccess {}
