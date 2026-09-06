import Darwin
import Dispatch
import FilaFileOps
import FilaFormats
import FilaProtocol
import Foundation

// `fila-archive`: the process `filad` spawns for one compress or extract.
//
// One `ArchiveHelperTask` as JSON on standard input, `ArchiveHelperLine`s one
// per line on standard output, `SIGTERM` to stop. It runs as whoever spawned
// it — root on a device — and touches the filesystem only through
// `FileOperations`, so the guard and the atomic replace are the daemon's own.
// See `ArchiveHelperRun` for the other side of the pipe, and
// `FilaJobKind.compress` for why this is a process at all.

let output = FileHandle.standardOutput
let encoder = JSONEncoder()

/// `FileHandle.write` is one `write(2)`, so a line lands whole or, when the
/// daemon has gone, raises the SIGPIPE that ends this process.
func emit(_ line: ArchiveHelperLine) {
    guard var data = try? encoder.encode(line) else { return }
    data.append(UInt8(ascii: "\n"))
    output.write(data)
}

guard let task = try? JSONDecoder().decode(ArchiveHelperTask.self, from: FileHandle.standardInput.readDataToEndOfFile()) else {
    emit(.completed(FilaFailure(code: .invalidRequest, systemError: EINVAL)))
    exit(EX_DATAERR)
}

let job = ArchiveJob(request: task.request, operations: FileOperations(bootstrapRoot: task.bootstrapRoot))

// Ignored at the signal level and delivered as an event instead, so the job
// stops at its next chunk and cleans up its temporary rather than leaving one.
signal(SIGTERM, SIG_IGN)
let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
stop.setEventHandler { job.cancel() }
stop.activate()

let outcome = job.run(report: { emit(.progress($0)) }, note: { emit(.note($0)) })
emit(.completed(outcome))
exit(outcome.code == .success ? EXIT_SUCCESS : EXIT_FAILURE)
