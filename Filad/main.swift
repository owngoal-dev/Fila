import Dispatch
import FilaLog
import FilaProtocol
import Foundation

autoreleasepool {
    do {
        // Names this process and sizes its log ring — 128 KiB, allocated once
        // and never grown, which is the whole of what logging costs a daemon
        // launchd will kill at 6 MB. See `FilaLogRing`.
        FilaLog.start(.daemon)
        FilaLog.info("filad started, pid \(getpid()), uid \(getuid())")
        let server = DaemonServer()
        try server.start()
        withExtendedLifetime(server) {
            dispatchMain()
        }
    } catch {
        // The ring dies with the process, so this line's only reader is
        // `log stream` — which is exactly the case os_log is here for.
        FilaLog.error("filad could not register \(FilaProtocol.serviceName)")
        exit(EXIT_FAILURE)
    }
}
