import AlertController
import FilaFileOps
import FilaLog
import FilaMedia
import FilaFormats
import FilaProtocol
import FilaProvider
import FilaTerminal
import UIKit

/// Explicit, one-shot device check available from Settings in every build.
@MainActor
enum FileOperationSelfTest {
    private static var isRunning = false

    /// A native entry point for checking the active backend on the device.
    static func present(from controller: UIViewController) {
        guard controller.presentedViewController == nil else { return }
        let alert = AlertViewController(
            title: "Run Self-Test?",
            message: "The self-test checks files, music editing, and app installation. Fila cannot be used for a few minutes. Keep it open until the results appear."
        ) { context in
            context.addAction(title: "Cancel") { context.dispose() }
            // "Run", not "Run Self-Test": the title already says what runs,
            // and the two keys differ only by the question mark, which the
            // catalogue's symbol generation cannot tell apart.
            context.addAction(title: "Run", attribute: .accent) {
                context.dispose { start(from: controller) }
            }
        }
        controller.present(alert, animated: true)
    }

    private static func start(from controller: UIViewController) {
        guard let navigation = controller.navigationController, let window = controller.viewIfLoaded?.window,
              controller.presentedViewController == nil else { return }
        let output = TerminalOutputViewController()
        output.title = String(localized: "Self-Test")
        navigation.pushViewController(output, animated: true)
        guard !isRunning, !FileClipboard.shared.isPasting, !FileSession.shared.operations.operations.contains(where: \.isRunning) else {
            output.appendLine("A file operation is still running. Wait for it to finish, then try again.", style: .warning)
            return
        }
        isRunning = true
        // This check borrows the real clipboard. Keep the whole window (also
        // the iPad sidebar) from replacing it until the original is restored.
        let wasInteractive = window.isUserInteractionEnabled
        window.isUserInteractionEnabled = false
        output.appendLine("Fila Self-Test", style: .bold)
        output.appendLine("Running isolated file checks…", style: .detail)
        Task {
            defer { window.isUserInteractionEnabled = wasInteractive }
            let report = Report(output: output)
            await run(report)
            report.summary()
        }
    }

    /// Sectioned PASS/FAIL lines as they happen, then a summary that repeats
    /// every failure so it is not lost among the passes.
    @MainActor
    private final class Report {
        private let output: TerminalOutputViewController
        private(set) var passed = 0
        private(set) var failures: [String] = []
        private(set) var skips: [String] = []

        init(output: TerminalOutputViewController) {
            self.output = output
        }

        func section(_ title: String) {
            output.appendLine("")
            output.appendLine(title, style: .heading)
        }

        func pass(_ check: String) {
            passed += 1
            output.append("[PASS] ", style: .pass)
            output.appendLine(check)
        }

        func fail(_ problem: String) {
            failures.append(problem)
            output.append("[FAIL] ", style: .fail)
            output.appendLine(problem)
        }

        /// A check the environment made impossible — not privileged, or an API
        /// this OS/jailbreak does not offer. Marked, counted, never a pass.
        func skip(_ reason: String) {
            skips.append(reason)
            output.append("[SKIP] ", style: .warning)
            output.appendLine(reason, style: .warning)
        }

        func summary() {
            section("Summary")
            output.appendLine("\(passed) passed, \(failures.count) failed, \(skips.count) skipped")
            for problem in failures { output.appendLine("[FAIL] " + problem, style: .fail) }
            output.appendLine("")
            output.appendLine(failures.isEmpty ? "SELF-TEST PASSED" : "SELF-TEST FAILED", style: failures.isEmpty ? .passVerdict : .fail)
        }
    }

    private struct Failed: Error, CustomStringConvertible {
        let description: String
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failed(description: message) }
    }

    private static func run(_ report: Report) async {
        let previousClipboard = (paths: FileClipboard.shared.paths, isCut: FileClipboard.shared.isCut)
        defer {
            if previousClipboard.paths.isEmpty { FileClipboard.shared.clear() }
            else { FileClipboard.shared.take(previousClipboard.paths, cut: previousClipboard.isCut) }
            isRunning = false
        }
        let session = FileSession.shared
        var temporaryDirectory: URL?
        do {
            report.section("Daemon")
            guard let hello = await session.ready(within: 15), hello.isPrivileged else {
                throw Failed(description: "A privileged daemon connection was not established")
            }
            report.pass("privileged XPC handshake")
            report.section("Clipboard and paste")
            let root = try await session.makeTemporaryDirectory()
            temporaryDirectory = root
            let source = root.appendingPathComponent("Source", isDirectory: true)
            let first = root.appendingPathComponent("First", isDirectory: true)
            let second = root.appendingPathComponent("Second", isDirectory: true)
            let moved = root.appendingPathComponent("Moved", isDirectory: true)
            for directory in [source, first, second, moved] {
                try await session.link.create(.directory, at: directory.path)
            }
            let name = "space # % ? 中文.txt"
            let file = source.appendingPathComponent(name)
            let bytes = Data("Fila copy/paste\n中文 # % ?\n".utf8)
            try await write(bytes, to: file)
            try await session.link.setAttributes(
                AttributeChange(mode: 0o640, extendedAttribute: ("wiki.qaq.fila.selftest", Data("metadata".utf8))),
                at: file.path
            )
            let empty = source.appendingPathComponent("Empty.txt")
            try await write(Data(), to: empty)
            let folder = source.appendingPathComponent("Folder", isDirectory: true)
            try await session.link.create(.directory, at: folder.path)
            try await write(bytes, to: folder.appendingPathComponent("Nested.txt"))
            let link = source.appendingPathComponent("Link")
            try await session.link.create(.symbolicLink(target: name), at: link.path)
            let sources = [file, empty, folder, link].map(\.path)

            let clipboard = FileClipboard.shared
            clipboard.take(sources, cut: false)
            try await paste(into: first, expecting: .success)
            try require(clipboard.paths == sources && !clipboard.isCut, "Copy must retain the clipboard")
            try require(try await read(first.appendingPathComponent(name)) == bytes, "Copied bytes differ")
            try require(try await read(file) == bytes, "Copy changed its source")
            try require(try await read(first.appendingPathComponent("Empty.txt")).isEmpty, "Empty copy differs")
            try require(try await read(first.appendingPathComponent("Folder/Nested.txt")) == bytes, "Nested copy differs")
            let copiedLink = try await session.link.details(of: first.appendingPathComponent("Link").path)
            try require(copiedLink.node.kind == .symbolicLink && copiedLink.node.link?.target == name, "Copy did not preserve the link")
            let copiedFile = try await session.link.details(of: first.appendingPathComponent(name).path)
            try require(copiedFile.node.mode & 0o777 == 0o640, "Copy lost the file mode")
            let attribute = try await session.link.extendedAttribute("wiki.qaq.fila.selftest", at: first.appendingPathComponent(name).path)
            try require(attribute == Data("metadata".utf8), "Copy lost the extended attribute")
            report.pass("browser paste: files, empty file, directory, symbolic link, mode and xattr")

            try await paste(into: second, expecting: .success)
            try require(try await read(second.appendingPathComponent(name)) == bytes, "Repeated paste differs")
            try require(clipboard.paths == sources, "Repeated paste lost the clipboard")
            report.pass("repeat copy paste retains clipboard")

            let collision = try await job(.copy, sources: [file.path], destination: first.path)
            try require(collision.systemError == EEXIST, "An existing target was not refused")
            try require(try await read(first.appendingPathComponent(name)) == bytes, "Collision changed the destination")
            report.pass("collision preserves destination")

            let cutSource = second.appendingPathComponent(name)
            clipboard.take([cutSource.path], cut: true)
            try await paste(into: moved, expecting: .success)
            try require(clipboard.isEmpty, "Successful move must clear its clipboard")
            try require(try await absent(cutSource), "Move left its source behind")
            try require(try await read(moved.appendingPathComponent(name)) == bytes, "Moved bytes differ")
            report.pass("browser cut/paste clears only after success")

            let missing = source.appendingPathComponent("Missing.txt")
            clipboard.take([missing.path], cut: true)
            try await paste(into: moved, expecting: .notFound)
            try require(clipboard.paths == [missing.path] && clipboard.isCut, "Failed move lost the clipboard")
            try require(try await absent(moved.appendingPathComponent("Missing.txt")), "Failed move created a destination")
            report.pass("failed browser paste retains clipboard")

            report.section("Save and transfers")
            let staged = try await session.stage(file.path)
            let stagedBytes = try? Data(contentsOf: staged)
            try FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            try require(stagedBytes == bytes, "Staged regular file bytes differ")
            let pipe = root.appendingPathComponent("StagePipe")
            try require(mkfifo(pipe.path, 0o600) == 0, "Could not create the staging pipe fixture")
            do {
                let unexpected = try await session.stage(pipe.path)
                try? FileManager.default.removeItem(at: unexpected.deletingLastPathComponent())
                throw Failed(description: "Staging accepted a named pipe as a regular file")
            } catch is Failed {
                throw Failed(description: "Staging accepted a named pipe as a regular file")
            } catch {}
            report.pass("staging preserves regular file bytes and refuses a named pipe")
            do {
                _ = try await session.read(source.path)
                throw Failed(description: "Reading a directory returned file bytes instead of an error")
            } catch is Failed {
                throw Failed(description: "Reading a directory returned file bytes instead of an error")
            } catch {
                report.pass("file reads report I/O errors instead of returning partial success")
            }
            let shrinking = root.appendingPathComponent("Shrinking.txt")
            try Data("original contents".utf8).write(to: shrinking)
            let opened = try await DescriptorFile.open(shrinking.path, link: session.link)
            defer { opened.close() }
            for size in [off_t(1), off_t(64)] {
                try require(truncate(shrinking.path, size) == 0, "Could not resize read fixture")
                do {
                    _ = try opened.readAll(limit: 1024)
                    throw Failed(description: "A resized file was accepted as a complete editable document")
                } catch is Failed {
                    throw Failed(description: "A resized file was accepted as a complete editable document")
                } catch {}
            }
            report.pass("shortened and grown files are refused as incomplete editable documents")
            // The same endpoint that editors use must publish a complete replacement.
            let temporary = source.appendingPathComponent("Replacement.tmp")
            let replacement = Data("replacement\n".utf8)
            try await write(replacement, to: temporary)
            try await session.link.replaceItem(at: file.path, withTemporary: temporary.path)
            let overwritten = try await job(.copy, sources: [file.path], destination: first.path, overwrite: true)
            try require(overwritten.code == .success, "Explicit file replacement failed")
            try require(try await read(first.appendingPathComponent(name)) == replacement, "Replacement bytes differ")
            report.pass("atomic save and explicit file replacement")

            clipboard.take([file.path], cut: true)
            guard let pending = clipboard.beginPaste() else { throw Failed(description: "Clipboard did not reserve its selection") }
            clipboard.take([empty.path], cut: false)
            clipboard.finishPaste(pending, succeeded: true)
            try require(clipboard.paths == [empty.path] && !clipboard.isCut, "An old completion cleared the new clipboard")
            report.pass("old transfer completion preserves a newer clipboard")

            report.section("ZIP")
            let archive = root.appendingPathComponent("Roundtrip.zip")
            let archived = try await job(.compress, sources: [file.path], destination: archive.path)
            try require(archived.code == .success, "ZIP creation failed: \(archived)")
            do {
                let descriptor = try await session.link.open(archive.path, flags: O_RDONLY)
                defer { close(descriptor) }
                let reader = try ArchiveReader(descriptor: descriptor)
                try require(try reader.next()?.declaredPath == name, "ZIP member name differs")
                try require(try reader.data(maximumByteCount: 4096) == replacement, "ZIP bytes differ")
                try require(try reader.next() == nil, "ZIP has unexpected members")
            }
            report.pass("ZIP creation preserves file name and bytes")

            let collisionZip = root.appendingPathComponent("Collision.zip")
            try await write(bytes, to: collisionZip)
            let archiveCollision = try await job(.compress, sources: [file.path], destination: collisionZip.path)
            try require(archiveCollision.systemError == EEXIST, "ZIP publication did not report its collision")
            try require(try await read(collisionZip) == bytes, "ZIP collision changed its destination")

            let cancelledZip = root.appendingPathComponent("Cancelled.zip")
            // Cancel synchronously from the writer's first progress callback.
            // This tests local writer cleanup; creation above exercises the live backend.
            let cancellationSource = root.appendingPathComponent("CancellationSource.txt")
            try replacement.write(to: cancellationSource)
            let cancelled = ArchiveJob(
                request: JobRequest(kind: .compress, sources: [cancellationSource.path], destination: cancelledZip.path, archive: ArchiveOptions()),
                operations: FileOperations(bootstrapRoot: session.installRoot ?? "", writableRoot: root.path)
            )
            let cancellation = await Task.detached { cancelled.run { _ in cancelled.cancel() } }.value
            try require(cancellation.code == .cancelled, "Cancelled ZIP was published: \(cancellation)")
            try require(try await absent(cancelledZip), "Cancelled ZIP left a destination")
            let entries = try await DirectoryReader.entries(in: root.path, session: session)
            try require(!entries.contains { $0.name.hasPrefix(".fila-archive-") }, "ZIP temporary was not cleaned up")
            report.pass("ZIP collision and cancellation preserve destinations and clean temporary files")
        } catch {
            report.fail(String(describing: error))
        }

        if let root = temporaryDirectory {
            report.section("Program launch")
            do {
                let invalid = root.appendingPathComponent("InvalidProgram")
                try await write(Data("Fila format fixture\n".utf8), to: invalid)
                try await session.link.setAttributes(AttributeChange(mode: 0o700, ownerID: getuid(), groupID: getgid()), at: invalid.path)
                do {
                    let terminal = try await session.link.openTerminal(executable: invalid.path, user: .mobile, columns: 80, rows: 24)
                    close(terminal.descriptor)
                    temporaryDirectory = nil
                    let deadline = ProcessInfo.processInfo.systemUptime + 5
                    while try await !session.link.closeTerminal(terminal.identifier) {
                        try require(ProcessInfo.processInfo.systemUptime < deadline, "Unconfirmed program exit; fixture retained at \(root.path)")
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                    temporaryDirectory = root
                    throw Failed(description: "An invalid program was reported as launched")
                } catch let failure as FilaFailure {
                    try require(failure.systemError == ENOEXEC, "Invalid program returned an unexpected failure: \(failure)")
                }
                report.pass("invalid executable format is reported through the privileged launch path")
            } catch {
                report.fail("program launch: \(error)")
            }

            report.section("File Provider backend")
            do {
                try await Task.detached { try checkFileProvider(at: root) }.value
                report.pass("provider backend creates, replaces, exports, renames and deletes an isolated file")
            } catch {
                report.fail("file provider backend: \(error)")
            }

            report.section("Music library")
            do {
                try await MusicLibraryEditor.shared.authorize()
                let snapshot = root.appendingPathComponent("MusicSnapshot.sqlitedb")
                try await Task.detached {
                    try MusicLibraryDatabase(path: MusicLibraryEditor.databasePath).backup(to: snapshot)
                    try NativeMusicLibrary.checkEditing(atSnapshotPath: snapshot.path)
                }.value
                report.pass("native song fields saved and reread in an isolated library snapshot")
            } catch {
                report.fail("music editing: \(error.localizedDescription)")
            }
        }

        // Owns its own fixture and cleanup, so it runs whether or not the checks
        // above threw. Skips (not fails) when the install API is unusable here.
        report.section("App installation")
        let install = await IPAInstaller.selfTestCheck()
        for proven in install.passes { report.pass(proven) }
        if let failure = install.failure { report.fail(failure) }
        else if let skipped = install.skipped { report.skip(skipped) }
        else { report.pass("install a probe app, verify it is registered, uninstall it, verify it is gone") }

        if let root = temporaryDirectory {
            report.section("Cleanup")
            do {
                try require(!FileClipboard.shared.isPasting, "Fixture cleanup not attempted while a paste is still running")
                FileClipboard.shared.clear()
                let result = try await job(.delete, sources: [root.path])
                try require(result.code == .success, "Fixture cleanup failed: \(result)")
                try require(try await absent(root), "Fixture still exists after cleanup")
                report.pass("fixture removed")
            } catch {
                report.fail(String(describing: error))
            }
        }
        FilaLog.info("File operation self-test \(report.failures.isEmpty ? "passed" : "failed"): \(report.passed) passed, \(report.failures.count) failed")
    }

    nonisolated private static func checkFileProvider(at root: URL) throws {
        let fixture = root.appendingPathComponent("Provider")
        let documents = fixture.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let tree = try ProviderTree(root: documents, index: fixture.appendingPathComponent("index.json"))
        let input = fixture.appendingPathComponent("input.txt")
        try Data("first".utf8).write(to: input)
        let created = try tree.createFile(name: "document.txt", parent: nil, contents: input)
        try Data("replacement".utf8).write(to: input)
        let replacement = try tree.replaceContents(of: created.id, with: input)
        let exported = fixture.appendingPathComponent("exported.txt")
        try tree.exportContents(of: replacement.id, to: exported)
        guard try Data(contentsOf: exported) == Data("replacement".utf8) else {
            throw Failed(description: "File Provider exported different bytes")
        }
        do {
            try tree.exportContents(of: replacement.id, to: exported)
            throw Failed(description: "File Provider overwrote an existing export")
        } catch ProviderTree.Failure.collision {}
        let moved = try tree.move(replacement.id, name: "renamed.txt", parent: nil)
        guard moved.id == replacement.id else { throw Failed(description: "File Provider lost identity after rename") }
        try tree.delete(moved.id, recursive: false)
        guard try tree.children(of: nil).isEmpty else { throw Failed(description: "File Provider retained a deleted file") }
    }

    private static func paste(into directory: URL, expecting code: FilaReplyCode) async throws {
        let center = FileSession.shared.operations
        let previous = Set(center.operations.map(\.id))
        let browser = BrowserViewController(directory: directory.path)
        browser.paste()
        try require(FileClipboard.shared.isPasting, "Browser did not start its paste")
        browser.paste() // A second tap while reserved must not start another job.
        let deadline = Date().addingTimeInterval(20)
        while FileClipboard.shared.isPasting {
            try require(Date() < deadline, "Browser paste did not finish")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Keep the real browser alive until its asynchronous action is done.
        withExtendedLifetime(browser) {}
        let completed = center.operations.filter { !previous.contains($0.id) }
        try require(completed.count == 1, "Browser paste started more than one operation")
        guard let operation = completed.first,
              case let .finished(result) = operation.state else {
            throw Failed(description: "Browser paste has no completed operation")
        }
        try require(result.code == code, "Unexpected browser paste result: \(result)")
    }

    private static func job(_ kind: FilaJobKind, sources: [String], destination: String? = nil, overwrite: Bool = false) async throws -> FilaFailure {
        let operationKind: OperationCenter.Kind
        switch kind {
        case .copy: operationKind = .copy
        case .move: operationKind = .move
        case .delete: operationKind = .delete
        case .compress: operationKind = .compress
        case .extract: operationKind = .extract
        case .search: throw Failed(description: "Search is not a transfer")
        }
        return try await FileSession.shared.operations.awaitJob(
            JobRequest(kind: kind, sources: sources, destination: destination, overwrite: overwrite, archive: kind.isArchive ? ArchiveOptions() : nil),
            kind: operationKind, subtitle: "Device self-test", feedback: .silent
        )
    }

    private static func write(_ data: Data, to url: URL) async throws {
        let descriptor = try await FileSession.shared.link.open(url.path, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o600)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    private static func read(_ url: URL) async throws -> Data {
        let descriptor = try await FileSession.shared.link.open(url.path, flags: O_RDONLY)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        return try handle.read(upToCount: 4096) ?? Data()
    }

    private static func absent(_ url: URL) async throws -> Bool {
        do { _ = try await FileSession.shared.link.details(of: url.path); return false }
        catch let failure as FilaFailure where failure.systemError == ENOENT { return true }
    }
}
