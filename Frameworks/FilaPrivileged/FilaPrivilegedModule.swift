import FilaCore
import Foundation

/// The privileged module: registers the link to `filad`.
///
/// Registration builds the link and nothing more. No lookup happens here —
/// `DaemonLink` asks the Mach service at its first handshake, and the grace
/// rule that decides between the daemon and the in-process service runs
/// then, on the app's own retry loop. A daemon that is not up yet is never
/// a bootstrap failure: the module registers whether or not `filad` will
/// ever answer, exactly as the app always has.
@objc(FilaPrivilegedModule)
public final class FilaPrivilegedModule: NSObject, BackendModule {
    public required override init() {
        super.init()
    }

    public func register(with registration: BackendRegistration) throws {
        try registration.provide(PrivilegedFileAccess.self, DaemonLink() as any PrivilegedFileAccess)
    }
}
