#if canImport(UIKit)
    /// What a terminal opens on.
    ///
    /// Three cases and no fourth, because the daemon only answers three questions:
    /// give me the login shell, run this file, or install this package. None
    /// carries arguments the client wrote — see `FilaOperation.openTerminal` for
    /// why there is no case that does.
    public enum TerminalProgram: Sendable, Equatable {
        /// The shell `filad` picks out of the bootstrap's own passwd database,
        /// started in `workingDirectory` when that is somewhere it can go.
        case loginShell(workingDirectory: String?)
        /// One executable, run with an argv of exactly itself, from the directory
        /// it sits in. The file menu chooses the user before presenting a terminal.
        case executable(path: String)
        /// A Debian package, handed to the bootstrap's `dpkg -i` as root. The
        /// daemon fixes the flag; the file is the only choice made here.
        case installPackage(path: String)
    }
#endif
