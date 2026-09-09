import FilaCore
import Foundation

/// The local module: one local filesystem backend per launch.
///
/// Which one depends on what this launch resolved, never on how it was
/// built. A sandboxed process gets its Documents directory and an access
/// object that cannot be anything but in-process, whichever modules are
/// beside it: the daemon is out of a sandbox's reach, and a privileged link
/// there would only wait out its grace period for nothing. Otherwise, with
/// the privileged module present, the backend is the full filesystem over
/// its link — the link itself decides at the handshake whether `filad` or
/// the in-process service answers, under the grace rule — and without it an
/// unsandboxed process still gets the full filesystem in-process.
@objc(FilaLocalModule)
public final class FilaLocalModule: NSObject, BackendModule {
    public required override init() {
        super.init()
    }

    public func register(with registration: BackendRegistration) throws {
        registration.backends { resolver in
            let host = resolver.host
            let environment = LocalFileBackend.Environment(inboxDirectory: host.inboxDirectory)
            let privileged = resolver.provider(PrivilegedFileAccess.self)
            if LocalFileService.processReach == .container {
                // A privileged module beside a sandboxed process is a
                // build whose entitlements did not all take: say so once,
                // because a copy quietly demoted to Documents looks like a
                // copy that never had more.
                if privileged != nil {
                    FilaLog.warning("local: the process is sandboxed; the privileged module is registered but out of reach and is not used")
                }
                // The container root is a different namespace from the full
                // root's, with its own record.
                let container = UserDefaultsStorage<LocalFilePreferences>(
                    defaults: host.defaults, key: "wiki.qaq.fila.local.container"
                )
                return [SandboxedLocalFileBackend(storage: container, environment: environment)]
            }
            // The full root keeps the keys the app always wrote.
            let fullRoot = LocalPreferencesDefaults(defaults: host.defaults)
            if let privileged {
                return [LocalFileBackend(access: privileged, storage: fullRoot, environment: environment)]
            }
            return [LocalFileBackend(access: LocalFileService(), storage: fullRoot, environment: environment)]
        }
    }
}
