import FilaCore
import Foundation

/// The entry point of `FilaLocal.framework`, found by name at startup.
///
/// Registers the local filesystem backend. The backend it produces depends on
/// which local-access provider another module supplied: the privileged module
/// offers root access through the daemon on a full build; without it, the
/// in-process access this framework carries is what the backend gets.
@objc(FilaLocalModule)
public final class FilaLocalModule: NSObject, BackendModule {
    public required override init() {
        super.init()
    }

    public func register(with registration: BackendRegistration) throws {
        // Phase 2 registers the local backend here.
    }
}
