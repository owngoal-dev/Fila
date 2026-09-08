import Darwin

// MARK: - Bootstrap vocabulary

/// Which of the three jailbreak layouts we are running under, and how a path
/// has to be spelled for whoever is going to read it.
///
/// Mixing the two spellings up is the classic bootstrap-path bug, so each
/// direction is its own function and every call site names the one it means.
/// The rule, copied from iGhostVT (which took it from roothide's own NewTerm):
///
/// - The path handed to `posix_spawn` must be what the **kernel** wants, because
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
    init(kind: Kind) {
        self.kind = kind
    }

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

    /// A kernel path passed as a program name to a bootstrap-linked shell.
    /// Bootstrap programs use their unprefixed name under roothide; programs
    /// outside that root are reached through its system-filesystem bridge.
    func programPath(_ path: String) -> String {
        guard case let .roothide(root) = kind else { return path }
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count))
        }
        return systemPath(path)
    }

    func isExecutableFile(_ bootstrapPath: String) -> Bool {
        TerminalPlan.isExecutableFile(resolve(bootstrapPath))
    }
}
