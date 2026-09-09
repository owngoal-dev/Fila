import FilaCore
import Foundation

/// The local module: one local filesystem backend per launch.
///
/// Which one depends on what this launch resolved, never on how it was
/// built. With the privileged module present, the backend is the full
/// filesystem over its link — the link itself decides at the handshake
/// whether `filad` or the in-process service answers, under the grace rule.
/// Without it, the in-process service says how far this process can see:
/// an unsandboxed process still gets the full filesystem, a sandboxed one
/// gets its Documents directory and an access object that cannot be
/// anything but in-process.
@objc(FilaLocalModule)
public final class FilaLocalModule: NSObject, BackendModule {
    public required override init() {
        super.init()
    }

    public func register(with registration: BackendRegistration) throws {
        registration.backends { resolver in
            if let privileged = resolver.provider(PrivilegedFileAccess.self) {
                return [LocalFileBackend(access: privileged)]
            }
            let local = LocalFileService()
            switch local.reach {
            case .user:
                return [LocalFileBackend(access: local)]
            case .container:
                return [SandboxedLocalFileBackend(access: local)]
            }
        }
    }
}
