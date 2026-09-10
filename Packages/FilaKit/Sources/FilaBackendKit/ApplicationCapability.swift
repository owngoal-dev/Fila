import Foundation

/// What a directory shows about the app that owns it: a name in place of a
/// container UUID, a detail line, and the identifier whose artwork to draw.
/// Display metadata only; the directory's real name stays the identity
/// every operation uses.
public struct FolderDecoration: Sendable, Hashable {
    public let name: String
    public let detail: String?
    public let applicationIdentifier: String?

    public init(name: String, detail: String?, applicationIdentifier: String?) {
        self.name = name
        self.detail = detail
        self.applicationIdentifier = applicationIdentifier
    }
}

/// Where an installed application keeps its bytes.
public struct ApplicationLocation: Sendable, Hashable {
    public let name: String
    public let bundleIdentifier: String
    public let bundlePath: String
    /// Nil when the app has no data container, or when only a bundle scan
    /// could answer — the mapping lives in the installation database.
    public let dataPath: String?

    public init(name: String, bundleIdentifier: String, bundlePath: String, dataPath: String?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.dataPath = dataPath
    }
}

/// What the Install… card says about a package, read from the package.
public struct PackageManifest: Sendable, Hashable {
    public let bundleIdentifier: String
    public let displayName: String

    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

/// What a package install attempt did. `unsupported` is not a failure: it
/// is the environment saying no install API is usable here.
public enum InstallOutcome: Sendable, Equatable {
    case installed
    case failed(domain: String, code: Int, message: String)
    case unsupported(String)
    /// The service stopped answering; neither cancellation nor refusal.
    case timedOut

    /// installd's "I will not trust this signature" — distinct from every
    /// other failure because the fix is a device-side tool.
    public var isSignatureRefusal: Bool {
        guard case let .failed(domain, code, message) = self else { return false }
        return (domain == "MIInstallerErrorDomain" && code == 13)
            || message.contains("0xe800801c") || message.contains("0xe8008015")
            || message.contains("code signature")
    }
}

/// The installed-applications capability, provided by the applications
/// module and absent from a build that does not bundle it. Everything the
/// shell needs about apps comes through here: whether the feature is on,
/// where an app lives, how a container is named, and the installer.
@MainActor
public protocol ApplicationCapability: AnyObject {
    /// Whether the feature is offered: whether the environment can see other
    /// apps at all.
    var isEnabled: Bool { get }

    /// The installed app registered under `bundleIdentifier`, or nil.
    func locate(bundleIdentifier: String) async -> ApplicationLocation?

    /// Decorations for the directories in `directory`, keyed by entry name.
    /// Empty when the feature is off or the directory is not one apps own.
    func decorations(in directory: String, entries: [(name: String, isDirectory: Bool)]) async -> [String: FolderDecoration]
    /// One lookup table for many paths — a breadcrumb asks once per crumb.
    func decorationLookup() async -> (String) -> FolderDecoration?

    /// Reads a package's identity from the staged copy of an `.ipa`.
    func manifest(ofPackageAt url: URL) async throws -> PackageManifest
    /// Hands a staged `.ipa` to the system installer.
    func install(packageAt url: URL) async -> InstallOutcome
}
