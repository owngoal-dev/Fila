import Darwin
import FilaProtocol
import Foundation

// MARK: - The spawn

/// Starts a terminal session through the daemon’s internal session-holder mode.
enum TerminalSpawn {
    private static let ptyAllocationLock = NSLock()
    static func run(
        _ plan: TerminalPlan,
        sessionHolder: String,
        columns: UInt16,
        rows: UInt16
    ) throws -> TerminalLaunch {
        func checked(_ error: Int32) throws {
            guard error == 0 else {
                throw FilaFailure(code: .operationFailed, systemError: error, path: plan.executable)
            }
        }
        // A session holder establishes the controlling terminal and credentials,
        // then uses an ordinary posix_spawn for the program. Neither process
        // forks or replaces itself; the holder remains waitable until cleanup.
        let arguments = [
            sessionHolder,
            "--terminal-session",
            plan.credential.map { String($0.uid) } ?? "-",
            String(plan.credential?.gid ?? 0),
            plan.workingDirectory ?? "/",
            plan.executable,
        ] + plan.arguments
        let argv = CStringArray(arguments)
        let envp = CStringArray(plan.environment.map { "\($0.key)=\($0.value)" }.sorted())
        defer { argv.deallocate(); envp.deallocate() }

        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        var slave: Int32 = -1
        // PTY allocation is short and serialized, including for concurrent host
        // clients. Darwin can refuse overlapping allocations with ENXIO.
        ptyAllocationLock.lock()
        let opened = openpty(&master, &slave, nil, nil, &size)
        let openError = Darwin.errno
        ptyAllocationLock.unlock()
        guard opened == 0 else { throw FilaFailure(errno: openError, path: plan.executable) }
        var transferred = false
        defer {
            close(slave)
            if !transferred {
                close(master)
            }
        }
        guard fcntl(master, F_SETFD, FD_CLOEXEC) == 0 else { throw FilaFailure(errno: Darwin.errno) }
        // Sources must survive actions overwriting 0/1/2 and report descriptor 3,
        // even when the parent was started with a standard descriptor closed.
        slave = try relocate(slave)
        var report: [Int32] = [-1, -1]
        guard pipe(&report) == 0 else { throw FilaFailure(errno: Darwin.errno) }
        defer { close(report[0]); close(report[1]) }
        report[1] = try relocate(report[1])
        guard fcntl(report[0], F_SETFD, FD_CLOEXEC) == 0 else { throw FilaFailure(errno: Darwin.errno) }

        var actions: posix_spawn_file_actions_t?
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        for destination in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            try checked(posix_spawn_file_actions_adddup2(&actions, slave, destination))
        }
        try checked(posix_spawn_file_actions_adddup2(&actions, report[1], 3))
        var attributes: posix_spawnattr_t?
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        var mask = sigset_t()
        sigfillset(&defaults)
        sigemptyset(&mask)
        try checked(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try checked(posix_spawnattr_setsigmask(&attributes, &mask))
        try checked(posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        ))
        var pid: pid_t = -1
        try checked(posix_spawn(&pid, sessionHolder, &actions, &attributes, argv.pointer, envp.pointer))
        close(report[1])
        report[1] = -1
        do {
            if let error = try readReport(report[0]) {
                try checked(error)
            }
        } catch {
            _ = killpg(pid, SIGKILL)
            _ = kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            throw error
        }
        transferred = true
        return TerminalLaunch(descriptor: master, process: TerminalProcess(processIdentifier: pid),
                              executable: plan.targetExecutable, launcher: plan.executable,
                              userIdentifier: plan.credential?.uid ?? getuid())
    }

    /// Moves an owned action source out of the fixed 0...3 destination range.
    /// On failure the caller still owns the original descriptor.
    private static func relocate(_ descriptor: Int32) throws -> Int32 {
        let moved = fcntl(descriptor, F_DUPFD_CLOEXEC, 4)
        guard moved >= 0 else { throw FilaFailure(errno: Darwin.errno) }
        close(descriptor)
        return moved
    }

    /// The holder acknowledges successful program spawn with an explicit zero.
    /// Empty EOF, a partial report or a read error leaves launch unconfirmed.
    static func readReport(_ descriptor: Int32) throws -> Int32? {
        var error: Int32 = 0
        return try withUnsafeMutablePointer(to: &error) { buffer in
            let wanted = MemoryLayout<Int32>.size
            var total = 0
            while total < wanted {
                let got = read(descriptor, UnsafeMutableRawPointer(buffer).advanced(by: total), wanted - total)
                if got > 0 {
                    total += got; continue
                }
                if got < 0 {
                    if Darwin.errno == EINTR {
                        continue
                    }
                    throw FilaFailure(errno: Darwin.errno)
                }
                throw FilaFailure(errno: EIO)
            }
            guard buffer.pointee >= 0 else { throw FilaFailure(errno: EIO) }
            return buffer.pointee == 0 ? nil : buffer.pointee
        }
    }
}

/// A NULL-terminated argv or environment for posix_spawn.
private struct CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ values: [String]) {
        count = values.count
        pointer = .allocate(capacity: values.count + 1)
        for (index, value) in values.enumerated() {
            pointer[index] = strdup(value)
        }
        pointer[values.count] = nil
    }

    func deallocate() {
        for index in 0 ..< count {
            free(pointer[index])
        }
        pointer.deallocate()
    }
}
