import FilaBackendKit
import Foundation

/// The local filesystem presented as a backend.
///
/// One instance per launch, made by the local module: the full-filesystem
/// backend at `/` over whatever local access the launch resolved — the
/// privileged link, which chooses the daemon or in-process at the handshake,
/// or the in-process service on its own — and nothing else. `Backend`
/// identity is the module's, not the access's: the same root is the same
/// backend whichever side ends up answering.
///
/// The class has exactly one subclass, in this module. Everything that
/// reads or writes a file stays in `FilaFileOps` behind `access`; what the
/// subclass changes is where navigation starts and which access it is
/// allowed to hold.
@MainActor
public class LocalFileBackend: FileBackend {
    public static let identifier = BackendID("local")

    public let id: BackendID
    public let root: BackendRoot
    /// The absolute path `root` stands for. `/` for the full backend.
    public let rootPath: String
    /// The local file layer: descriptors, attributes, jobs. Consumers that
    /// need the local contract take this; everything else takes
    /// `fileService()`.
    public let access: any LocalFileAccess

    private lazy var service = LocalFileServiceAdapter(access: access, rootPath: rootPath)

    /// Immutable inputs first, then shared behaviour: nothing here calls a
    /// hook a subclass may not be ready to answer. `rootPath` must be
    /// absolute; a trailing separator is dropped so paths join cleanly.
    public init(access: any LocalFileAccess, rootPath: String, displayName: String, symbolName: String) {
        precondition(rootPath.hasPrefix("/"), "a local root is an absolute path")
        id = LocalFileBackend.identifier
        self.access = access
        var normalized = rootPath
        while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
        self.rootPath = normalized
        root = BackendRoot(
            location: .root(of: LocalFileBackend.identifier),
            kind: .filesystem,
            displayName: displayName,
            symbolName: symbolName
        )
    }

    /// The full filesystem, from `/`.
    public convenience init(access: any LocalFileAccess) {
        self.init(access: access, rootPath: "/", displayName: "Local Files", symbolName: "internaldrive")
    }

    public func fileService() async throws -> any FileService {
        service
    }

    /// The absolute path for a location under this root — lexical, and safe
    /// because `ServicePath` admits no component that could climb out.
    public func absolutePath(_ path: ServicePath) -> String {
        service.absolutePath(path)
    }
}

/// The local backend a sandboxed process gets: the app's own Documents
/// directory, over in-process access, and no way to be handed anything else.
///
/// The type of `access` is the concrete in-process service on purpose. A
/// privileged link cannot be passed here, so a later reconnect cannot
/// promote this backend and privileged code cannot obtain daemon access
/// through it. The OS sandbox is what enforces the boundary on every
/// operation; this class only describes where navigation starts.
@MainActor
public final class SandboxedLocalFileBackend: LocalFileBackend {
    /// `documents` defaults to the process's own Documents directory,
    /// resolved now rather than stored: a container's installation UUID
    /// is not a stable location.
    public init(access: LocalFileService = LocalFileService(), documents: URL? = nil) {
        super.init(
            access: access,
            rootPath: (documents ?? SandboxedLocalFileBackend.documentsDirectory()).path,
            displayName: "Documents",
            symbolName: "folder"
        )
    }

    static func documentsDirectory() -> URL {
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        return URL(fileURLWithPath: paths.first ?? NSHomeDirectory() + "/Documents", isDirectory: true)
    }
}
