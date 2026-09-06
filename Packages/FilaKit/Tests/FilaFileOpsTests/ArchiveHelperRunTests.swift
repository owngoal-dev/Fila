import Darwin
import Foundation
import Testing

@testable import FilaFileOps
@testable import FilaProtocol

/// The pipe between `filad` and `fila-archive`, driven against a shell script
/// standing in for the helper: what the daemon writes down, what it reads
/// back, and what a cancel does to the child.
@Suite("Archive helper", .serialized)
struct ArchiveHelperRunTests {
    let scratch = Scratch()

    private func helper(_ body: String) -> String {
        let path = scratch.file("helper.sh", contents: "#!/bin/sh\n" + body + "\n", mode: 0o755)
        return path
    }

    private func line(_ value: ArchiveHelperLine) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func request() -> JobRequest {
        JobRequest(kind: .compress, sources: [scratch.file("source")], destination: scratch.path("out.zip"), archive: ArchiveOptions())
    }

    @Test("The task goes down as JSON, and progress, notes and the outcome come back by line")
    func relaysLines() throws {
        let progress = try line(.progress(JobProgress(bytesDone: 1, bytesTotal: 2, itemsDone: 3, itemsTotal: 4, currentPath: "x")))
        let note = try line(.note("skipped one"))
        let completed = try line(.completed(FilaFailure(code: .wrongPassword, path: "y")))
        let script = helper("""
        task="$(cat)"
        case "$task" in *'"kind":5'*) ;; *) exit 3 ;; esac
        case "$task" in *'"bootstrapRoot":"'*) ;; *) exit 3 ;; esac
        printf '%s\\n' '\(progress)' '\(note)' '\(completed)'
        """)
        let operations = FileOperations(bootstrapRoot: scratch.root, archiveHelper: script)
        var seen: [JobProgress] = []
        var notes: [String] = []
        let outcome = FileJob(request: request(), operations: operations).run { seen.append($0) } note: { notes.append($0) }
        #expect(outcome.code == .wrongPassword)
        #expect(outcome.path == "y")
        #expect(seen == [JobProgress(bytesDone: 1, bytesTotal: 2, itemsDone: 3, itemsTotal: 4, currentPath: "x")])
        #expect(notes == ["skipped one"])
    }

    @Test("A helper that dies without an outcome is a failure, not a success")
    func deathWithoutOutcome() {
        let operations = FileOperations(bootstrapRoot: scratch.root, archiveHelper: helper("cat >/dev/null; exit 9"))
        var notes: [String] = []
        let outcome = FileJob(request: request(), operations: operations).run { _ in } note: { notes.append($0) }
        #expect(outcome.code == .operationFailed)
        #expect(notes.first?.contains("exited") == true)
    }

    @Test("A missing helper fails with the errno rather than hanging")
    func missingHelper() {
        let operations = FileOperations(bootstrapRoot: scratch.root, archiveHelper: scratch.path("absent"))
        let outcome = FileJob(request: request(), operations: operations).run { _ in }
        #expect(outcome.systemError == ENOENT)
    }

    @Test("Cancel hangs the helper up and the job reports cancelled")
    func cancelSignalsChild() {
        let operations = FileOperations(bootstrapRoot: scratch.root, archiveHelper: helper("cat >/dev/null; exec sleep 30"))
        let job = FileJob(request: request(), operations: operations)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { job.cancel() }
        let started = Date()
        let outcome = job.run { _ in }
        #expect(outcome.code == .cancelled)
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
