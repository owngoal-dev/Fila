#if canImport(UIKit)
    import Darwin
    import FilaClient
    import FilaLog
    import FilaProtocol
    import Foundation
    import GhosttyTerminal
    import LocalAuthentication
    import SnapKit
    import Then
    import UIKit

    /// What runs on the main actor once the daemon has reaped the spawned child,
    /// carried as a value rather than as a bare function.
    ///
    /// Reading a `@MainActor` function out of a stored property *from* the main
    /// actor strips the isolation from the value's type, so handing it on to the
    /// nonisolated cleanup below converted it back at every call site — four
    /// "may introduce data races" warnings for a handler that never left the main
    /// actor. A struct is not a function type, so nothing is erased and nothing is
    /// converted back.
    private struct TerminalExitHandler: Sendable {
        let run: @MainActor @Sendable () -> Void
    }

    /// A terminal on a program `filad` spawned.
    ///
    /// The screen owns the pseudo-terminal master and pumps it (`TerminalPTY`);
    /// libghostty owns the emulation and the drawing. The daemon is out of the way
    /// as soon as it has answered — it holds the pid so it can hang the session up,
    /// and nothing else.
    public final class TerminalViewController: UIViewController {
        /// - Parameters:
        ///   - program: what to run.
        ///   - user: the identity explicitly selected in the Run menu.
        ///   - redirectsScriptInterpreter: the Behavior setting, carried rather
        ///     than read, because this package is not the app and has no
        ///     preferences of its own.
        ///   - link: the app's connection to `filad`.
        public init(program: TerminalProgram, user: TerminalUser,
                    redirectsScriptInterpreter: Bool = false, link: DaemonLink,
                    onProcessExit: (@MainActor @Sendable () -> Void)? = nil)
        {
            self.program = program
            requestedUser = user
            self.redirectsScriptInterpreter = redirectsScriptInterpreter
            self.link = link
            self.onProcessExit = onProcessExit.map(TerminalExitHandler.init(run:))
            super.init(nibName: nil, bundle: nil)
            title = Self.name(of: program)
            // Ending the session remains available in the screen's action menu.
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "ellipsis"),
                menu: UIMenu(children: [
                    UIAction(
                        title: String(localized: "End Session", bundle: .module),
                        image: UIImage(systemName: "stop"),
                        attributes: .destructive
                    ) { [weak self] _ in
                        self?.endSession()
                    },
                ])
            )
            navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "More", bundle: .module)
            navigationItem.rightBarButtonItem?.isEnabled = false
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        private let program: TerminalProgram
        private let redirectsScriptInterpreter: Bool
        private let link: DaemonLink
        /// Optional owner cleanup after the daemon has reaped the direct child.
        /// An unknown launch/termination outcome deliberately retains its input.
        private let onProcessExit: TerminalExitHandler?
        /// Holds what the terminal surface needs to reach across threads: the pump,
        /// once the daemon has answered, and the grid size, which libghostty
        /// reports before there is anything to report it to.
        private let pump = PumpBox()

        private lazy var terminalView = TerminalView(frame: .zero)
        private let sessionNotice = UIListContentView(configuration: .groupedFooter())

        /// Built with a theme and a configuration rather than bare. A bare
        /// `TerminalController()` takes the library's own defaults, and the surface
        /// is drawn by libghostty rather than by UIKit, so nothing else in the app
        /// corrects them afterwards.
        ///
        /// Alabaster and Afterglow are the library's own named themes and the ones
        /// iGhostVT falls back to. The point of naming a pair rather than one is
        /// that a terminal is the only screen here whose colours libghostty owns:
        /// the rest of the app follows the system automatically and this would not.
        ///
        /// **10 points, not a body-text size.** A terminal is a grid, so the font
        /// size is how many columns fit — 80 columns is the width most command
        /// output is written for, and at 17pt a phone gets about 30. The number is
        /// the library's own iOS default rather than a guess.
        ///
        /// The blink is deliberate and not decoration. A session that has connected
        /// but whose program has not printed yet has only the cursor to say it is
        /// alive, and on a jailbroken device that gap can be tens of seconds after
        /// a respring — every binary the shell's rc files exec pays for its first
        /// trustcache check. A still cursor reads as dead; a blinking one reads as
        /// waiting. A program that sets DECSCUSR still wins.
        private lazy var terminalController = TerminalController(
            theme: TerminalAppearance.theme,
            terminalConfiguration: TerminalConfiguration { builder in
                builder.withFontSize(TerminalAppearance.fontSize)
                builder.withCursorStyleBlink(true)
                // Fila reports launch failures itself. A fast PTY EOF is not one.
                builder.withCustom("abnormal-command-exit-runtime", "0")
            }
        )

        private lazy var session = InMemoryTerminalSession(
            write: { [pump] data in pump.pty?.send(data) },
            resize: { [pump] viewport in
                pump.columns = viewport.columns
                pump.rows = viewport.rows
                pump.pty?.resize(columns: viewport.columns, rows: viewport.rows)
            }
        )
        private lazy var statusLabel = UILabel().then {
            $0.numberOfLines = 0
            $0.textAlignment = .center
            $0.textColor = .label
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
        }

        /// The request comes from the menu; the displayed identity comes from the daemon.
        private let requestedUser: TerminalUser
        private var terminalIdentifier: DaemonLink.TerminalIdentifier?
        private var hasStarted = false
        private var authentication: LAContext?
        /// When the daemon handed the descriptor back, which is the earliest moment
        /// the program can be said to have been running. Not when the screen
        /// appeared: the handshake and the spawn are Fila waiting, not the program.
        private var startedAt = Date()
        private var isFinished = false

        // MARK: - Lifecycle

        override public func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = TerminalAppearance.background

            terminalView.do {
                $0.delegate = self
                $0.controller = terminalController
                // Fila keeps the output and owns the end-of-session UI.
                $0.configuration = TerminalSurfaceOptions(
                    backend: .inMemory(session),
                    waitAfterCommand: false
                )
                $0.isHidden = true
            }
            sessionNotice.do {
                $0.setContentHuggingPriority(.required, for: .vertical)
                $0.setContentCompressionResistancePriority(.required, for: .vertical)
            }
            view.addSubview(terminalView)
            view.addSubview(sessionNotice)
            view.addSubview(statusLabel)
            terminalView.snp.makeConstraints { make in
                make.top.equalTo(view.safeAreaLayoutGuide)
                make.leading.trailing.equalToSuperview()
                // The keyboard guide, not the safe area: an on-screen keyboard that
                // covered the last rows would hide the line being typed.
                make.bottom.equalTo(sessionNotice.snp.top)
            }
            sessionNotice.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview()
                make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
            }
            statusLabel.snp.makeConstraints { make in
                make.centerX.equalToSuperview()
                make.centerY.equalTo(view.safeAreaLayoutGuide)
                make.width.equalTo(view.readableContentGuide).offset(-32)
            }
        }

        override public func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            terminalView.fitToSize()
        }

        override public func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !hasStarted, !isFinished else { return }
            // Only an explicit Run action constructs this screen. A file tap opens its viewer.
            start()
        }

        private func start() {
            hasStarted = true
            statusLabel.text = String(localized: "Starting…", bundle: .module)
            navigationItem.rightBarButtonItem?.isEnabled = true
            authenticateAndOpen()
        }

        /// Authenticate each root launch, including programs and package installs.
        /// This is a UI gate, not a replacement for the daemon's peer authentication.
        private func authenticateAndOpen() {
            guard requestedUser == .root else { open(); return }
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                if error?.domain == LAError.errorDomain, error?.code == LAError.passcodeNotSet.rawValue {
                    open()
                } else {
                    authenticationFailed(error)
                }
                return
            }
            authentication = context
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "Authenticate to run a terminal session as root.", bundle: .module)
            ) { [weak self] success, error in
                Task { @MainActor [weak self] in
                    guard let self, !self.isFinished else { return }
                    authentication = nil
                    if success {
                        open()
                    } else {
                        authenticationFailed(error)
                    }
                }
            }
        }

        private func authenticationFailed(_ error: Error?) {
            isFinished = true
            navigationItem.rightBarButtonItem?.isEnabled = false
            statusLabel.text = error?.localizedDescription ?? String(localized: "Authentication failed.", bundle: .module)
            // No launch request was sent, so staged input can be released now.
            onProcessExit?.run()
        }

        override public func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            // Popped, dismissed, or the containing tab was closed: the shell goes
            // with the screen. Nothing here reattaches to a running session, and a
            // root shell nobody can see is exactly what must not be left behind.
            if isBeingDismissed || isMovingFromParent || parent?.isMovingFromParent == true {
                teardown()
            }
        }

        deinit {
            authentication?.invalidate()
            // Not `teardown()`: that would need `self` on the main actor, and there
            // is no `self` left to give it. Everything it does is done here from
            // values instead — the pump releases its descriptor, and the daemon is
            // told to hang the process up rather than being left to notice when the
            // whole app goes.
            pump.pty?.close()
            guard let identifier = terminalIdentifier else { return }
            Self.close(identifier, link: link, onProcessExit: onProcessExit)
        }

        // MARK: - The session

        private func open() {
            let program = program
            let link = link
            let columns = pump.columns
            let rows = pump.rows
            let user = requestedUser
            let redirectsScriptInterpreter = redirectsScriptInterpreter
            let onProcessExit = onProcessExit
            Task { [weak self] in
                while true {
                    guard self?.isFinished == false else { return }
                    do {
                        let terminal = try await link.openTerminal(
                            executable: program.executablePath,
                            package: program.packagePath,
                            user: user,
                            redirectsScriptInterpreter: redirectsScriptInterpreter,
                            workingDirectory: program.workingDirectory,
                            columns: columns,
                            rows: rows
                        )
                        guard let self else {
                            // The screen can disappear while launch is pending.
                            // A successful reply still transfers a real descriptor
                            // and process, even when nobody can attach them now.
                            Darwin.close(terminal.descriptor)
                            Self.close(terminal.identifier, link: link, onProcessExit: onProcessExit)
                            return
                        }
                        attach(terminal)
                        return
                    } catch let failure as FilaFailure where Self.isDaemonMissing(failure) {
                        // `filad` is on-demand and its absence is never an error —
                        // a jailbreak that just resprang takes a moment, and there
                        // is nothing the user could do about it. Keep saying
                        // *Starting…* and keep asking, the way the handshake does.
                        let stillWanted = await MainActor.run { self?.isFinished == false }
                        guard stillWanted else { return }
                        link.invalidate()
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        // A refusal, as opposed to a daemon that has not come up
                        // yet — the loop above never leaves a line because it is
                        // the ordinary case. This one ends the screen.
                        FilaLog.warning("terminal could not start \(program.executablePath ?? "the shell"): \(error)")
                        await MainActor.run { self?.present(failure: error) }
                        return
                    }
                }
            }
        }

        /// The daemon has not answered, as opposed to having refused. `ENOENT` is
        /// the Mach service not being registered yet and `ECONNRESET` is the link
        /// dying under the request; everything else is a decision the daemon made,
        /// and the user needs to read it.
        ///
        /// **A named path is what separates the two.** A link that was never
        /// reached knows no path, while a child that failed `execve` reports the
        /// program it could not run — and that failure is `.operationFailed` with
        /// the child's `errno`, which for a script whose shebang interpreter does
        /// not exist is `ENOENT`, the same pair. Without this the daemon's real
        /// refusal was swallowed and the screen retried it forever, saying
        /// *Starting…* at a program that was never going to start.
        private static func isDaemonMissing(_ failure: FilaFailure) -> Bool {
            failure.code == .operationFailed
                && failure.path == nil
                && (failure.systemError == ENOENT || failure.systemError == ECONNRESET)
        }

        private func attach(_ terminal: DaemonLink.Terminal) {
            guard !isFinished else {
                // Closed while the daemon was answering. The descriptor is real and
                // ours, so it has to be released, and the process with it.
                Darwin.close(terminal.descriptor)
                Self.close(terminal.identifier, link: link, onProcessExit: onProcessExit)
                return
            }
            // The daemon logged what it spawned and as whom. This is the app's
            // half: the pair is what tells a session that ran from one that
            // opened and closed in the same second.
            FilaLog.info("terminal attached, uid \(terminal.userIdentifier)")
            terminalIdentifier = terminal.identifier
            startedAt = Date()
            terminalView.isHidden = false
            guardAgainstDismissal(true)

            let pty = TerminalPTY(descriptor: terminal.descriptor)
            pty.onOutput = { [session] data in session.receive(data) }
            pty.onEnd = { [weak self] in
                Task { @MainActor in self?.programEnded() }
            }
            pump.pty = pty
            pty.resize(columns: pump.columns, rows: pump.rows)
            pty.start()

            statusLabel.text = nil
            // Said plainly and permanently, because it is the single most important
            // fact about this screen: who everything typed here runs as.
            //
            // Read off the uid the daemon reports, never off `requestedUser`. The
            // app asked for one of two users; only the daemon knows which one it
            // resolved, and a screen that echoed the request would keep saying
            // "mobile" for a session that is quietly root. The two-way branch is
            // exhaustive because `TerminalUser` is: uid 0 is the root session, and
            // the only other user this daemon will ever spawn as is `mobile`.
            showSessionNotice(terminal.isRoot
                ? String(localized: "Running as root", bundle: .module)
                : String(localized: "Running as mobile", bundle: .module))
            // The keyboard is not raised for the user. A session often starts by
            // printing rather than by asking, and a screen that opens with half of
            // itself covered hides the output that says what happened. Tapping the
            // terminal is the whole cost of typing.
        }

        /// A package install must not be hung up by a swipe: `dpkg` left between
        /// unpack and configure is exactly the damage the card warned about, and
        /// an edge-swipe is not a decision. The back button and the pop gesture
        /// go away while the child is alive; the End action stays, because it is
        /// one. A closed tab or a killed app still hangs it up — those the screen
        /// cannot intercept.
        private func guardAgainstDismissal(_ on: Bool) {
            guard case .installPackage = program else { return }
            navigationItem.hidesBackButton = on
            navigationController?.interactivePopGestureRecognizer?.isEnabled = !on
        }

        private func programEnded() {
            guard !isFinished else { return }
            isFinished = true
            // The identifier belongs to the daemon's line a moment earlier; what
            // this side knows and it does not is how long the program ran.
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            FilaLog.info("terminal ended after \(elapsedMilliseconds)ms")
            guardAgainstDismissal(false)
            terminalView.resignFirstResponder()
            statusLabel.text = nil
            showSessionNotice(String(localized: "Session ended", bundle: .module))
            navigationItem.rightBarButtonItem?.isEnabled = false
            // The terminal keeps what the program printed on screen — the last
            // lines are usually the reason it ended.
            //
            // EOF does not carry the child's wait status. This only closes the
            // renderer's input; the UI says "Session ended", never "Succeeded".
            session.finish(
                exitCode: 0,
                runtimeMilliseconds: UInt64((Date().timeIntervalSince(startedAt) * 1000).rounded())
            )
            // The pump already read to EOF, so there is nothing left to take off
            // the descriptor; holding it would leak a master and its dispatch
            // sources for as long as the finished screen stays on display.
            pump.pty?.close()
            pump.pty = nil
            releaseTerminal()
        }

        @objc private func endSession() {
            teardown()
            guardAgainstDismissal(false)
            terminalView.resignFirstResponder()
            statusLabel.text = nil
            showSessionNotice(String(localized: "Session ended", bundle: .module))
            navigationItem.rightBarButtonItem?.isEnabled = false
        }

        private func teardown() {
            guard !isFinished else { return }
            isFinished = true
            if let authentication {
                authentication.invalidate()
                self.authentication = nil
                onProcessExit?.run()
            }
            // Closing the master revokes the terminal and the kernel hangs the
            // session up; the daemon's kill is what settles a program that ignored
            // it. Both, always — neither is reliable alone.
            pump.pty?.close()
            pump.pty = nil
            releaseTerminal()
        }

        private func releaseTerminal() {
            guard let identifier = terminalIdentifier else { return }
            terminalIdentifier = nil
            Self.close(identifier, link: link, onProcessExit: onProcessExit)
        }

        private nonisolated static func close(_ identifier: DaemonLink.TerminalIdentifier, link: DaemonLink,
                                              onProcessExit: TerminalExitHandler?)
        {
            Task {
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                do {
                    repeat {
                        if try await link.closeTerminal(identifier) {
                            await onProcessExit?.run()
                            return
                        }
                        guard onProcessExit != nil else { return }
                        try await Task.sleep(nanoseconds: 250_000_000)
                    } while ProcessInfo.processInfo.systemUptime < deadline
                } catch {
                    // A lost reply or elapsed grace does not prove completion.
                    // The app-owned input is left for later workspace cleanup.
                }
            }
        }

        private func present(failure: Error) {
            isFinished = true
            navigationItem.rightBarButtonItem?.isEnabled = false
            statusLabel.text = Self.message(for: failure)
        }

        private func showSessionNotice(_ text: String) {
            var content = UIListContentConfiguration.groupedFooter()
            content.text = text
            sessionNotice.configuration = content
        }

        // MARK: - Text

        private static func name(of program: TerminalProgram) -> String {
            switch program {
            case .loginShell: String(localized: "Terminal", bundle: .module)
            case let .executable(path), let .installPackage(path): (path as NSString).lastPathComponent
            }
        }

        private static func message(for failure: Error) -> String {
            let summary = String(
                localized: "This program could not be started. Check that it exists and can be run.",
                bundle: .module
            )
            // The system's own reason stays in the message: on a jailbroken device
            // "Operation not permitted" (a binary AMFI refused) and "No such file
            // or directory" are the two likely answers, and only one of them is
            // something the user can do anything about.
            guard let reason = (failure as? FilaFailure)?.systemErrorDescription else { return summary }
            return summary + "\n" + reason
        }
    }

    // MARK: - Surface delegate

    extension TerminalViewController: TerminalSurfaceTitleDelegate {
        public func terminalDidChangeTitle(_ title: String) {
            // A shell with integration reports what it is running; a bare one never
            // does, and the program's own name is the better answer than an empty
            // bar.
            navigationItem.title = title.isEmpty ? Self.name(of: program) : title
        }
    }

    // MARK: - Cross-thread state

    /// What the terminal surface reaches for from whichever thread it is on.
    ///
    /// libghostty reports a viewport before the daemon has answered — the surface
    /// is measured as soon as it is laid out — so the size has to be somewhere the
    /// pump can pick up when it arrives.
    private final class PumpBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedPTY: TerminalPTY?
        private var storedColumns: UInt16 = 80
        private var storedRows: UInt16 = 24

        /// `NSLock.withLock` is iOS 16, and this project has an iOS 15 floor and no
        /// `if #available` anywhere.
        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        var pty: TerminalPTY? {
            get { locked { storedPTY } }
            set { locked { storedPTY = newValue } }
        }

        var columns: UInt16 {
            get { locked { storedColumns } }
            set { locked { storedColumns = newValue } }
        }

        var rows: UInt16 {
            get { locked { storedRows } }
            set { locked { storedRows = newValue } }
        }
    }

    private extension TerminalProgram {
        var executablePath: String? {
            switch self {
            case .loginShell, .installPackage: nil
            case let .executable(path): path
            }
        }

        var packagePath: String? {
            switch self {
            case .loginShell, .executable: nil
            case let .installPackage(path): path
            }
        }

        /// Where the session starts. Running a file starts in the folder it was
        /// found in, which is what the user was looking at when they tapped it.
        var workingDirectory: String? {
            switch self {
            case let .loginShell(directory): directory
            case let .executable(path), let .installPackage(path): (path as NSString).deletingLastPathComponent
            }
        }
    }
#endif
