import Foundation

/// The entry class of a bundled backend framework.
///
/// Discovery derives its name from the framework: `FilaLocal.framework` must
/// contain a class whose Objective-C runtime name is exactly `FilaLocalModule`.
/// Declare it `@objc(FilaLocalModule)`, non-generic, on `NSObject`, and it is
/// found by name after dyld has loaded the framework — no `+load`, no global
/// initializer, no hard-coded switch in the app.
///
/// `register(with:)` builds factories and lightweight contributions only. It
/// must not connect to a server, enumerate installed applications, create a
/// view controller or ask the user for anything: the app is not on screen yet.
public protocol BackendModule: NSObject {
    init()

    /// Called once per launch, on the main actor, before `UIApplicationMain`.
    /// Throwing leaves nothing registered from this module.
    @MainActor
    func register(with registration: BackendRegistration) throws
}

/// What the app supplies to modules. Modules never reach for a singleton;
/// everything they need to persist, report or present comes through here.
@MainActor
public protocol BackendHost: AnyObject {
    /// Developer diagnostics. Bootstrap problems go to `warn` and nowhere
    /// the user can see them; `log` is for the ordinary startup record.
    func log(_ message: String)
    func warn(_ message: String)
}

/// A module's registrations, collected while `register(with:)` runs and
/// committed to the registry as one unit afterwards. If any part of the
/// commit is refused — a provider another module already supplied, a
/// second module with the same identity — none of it is applied.
@MainActor
public final class BackendRegistration {
    public let module: BackendModuleIdentity
    public let host: any BackendHost

    var providers: [ObjectIdentifier: (name: String, value: Any)] = [:]
    var backendFactories: [BackendFactory] = []

    init(module: BackendModuleIdentity, host: any BackendHost) {
        self.module = module
        self.host = host
    }

    /// Publish a capability other modules resolve by protocol. Providers are
    /// resolved only after every module has registered, so registration
    /// order between frameworks does not decide availability.
    public func provide<Provider>(_ type: Provider.Type, _ provider: Provider) throws {
        let key = ObjectIdentifier(type)
        let name = String(describing: type)
        guard providers[key] == nil else {
            throw BackendModuleError.duplicateProvider(name)
        }
        providers[key] = (name, provider)
    }

    /// Register the backends this module supplies. The factory runs once all
    /// modules have registered, with the completed provider set. Returning an
    /// empty array is the way a module says a backend it could offer is not
    /// available on this launch.
    public func backends(_ make: @escaping @MainActor (BackendResolver) throws -> [any Backend]) {
        backendFactories.append(BackendFactory(module: module, make: make))
    }
}

/// Read access to the committed registry, handed to backend factories.
@MainActor
public struct BackendResolver {
    public let host: any BackendHost
    let registry: BackendRegistry

    /// The provider registered for `type`, or nil when no bootstrapped module
    /// supplied it. A factory whose requirement is missing returns no
    /// backends; it does not fall back to something weaker.
    public func provider<Provider>(_ type: Provider.Type) -> Provider? {
        registry.provider(type)
    }
}

struct BackendFactory {
    let module: BackendModuleIdentity
    let make: @MainActor (BackendResolver) throws -> [any Backend]
}

/// Who a module is: taken from its framework bundle, never from a field the
/// module could edit independently.
public struct BackendModuleIdentity: Hashable, Sendable, CustomStringConvertible {
    public let bundleIdentifier: String
    /// The framework's basename, `FilaLocal` for `FilaLocal.framework`; also
    /// the prefix of the entry class name.
    public let frameworkName: String
    /// The key of the module's localized display name in its own bundle.
    public let displayNameKey: String

    public init(bundleIdentifier: String, frameworkName: String, displayNameKey: String) {
        self.bundleIdentifier = bundleIdentifier
        self.frameworkName = frameworkName
        self.displayNameKey = displayNameKey
    }

    public var entryClassName: String { frameworkName + "Module" }

    public var description: String { bundleIdentifier }
}

public enum BackendModuleError: Error, Equatable, CustomStringConvertible {
    case manifest(String)
    case schemaMismatch(Int)
    case contractMismatch(Int)
    case versionMismatch(module: String, host: String)
    case entryClassMissing(String)
    case entryClassForeign(String)
    case entryClassNotConforming(String)
    case duplicateProvider(String)
    case duplicateModule(String)
    case registration(String)

    public var description: String {
        switch self {
        case let .manifest(reason):
            return "manifest: \(reason)"
        case let .schemaMismatch(found):
            return "manifest schema \(found), host reads \(FilaBackendKit.manifestSchemaVersion)"
        case let .contractMismatch(found):
            return "contract \(found), host is \(FilaBackendKit.contractVersion)"
        case let .versionMismatch(module, host):
            return "module version \(module) differs from host \(host)"
        case let .entryClassMissing(name):
            return "entry class \(name) not found"
        case let .entryClassForeign(name):
            return "entry class \(name) belongs to another bundle"
        case let .entryClassNotConforming(name):
            return "entry class \(name) does not conform to BackendModule"
        case let .duplicateProvider(name):
            return "provider \(name) already registered"
        case let .duplicateModule(identifier):
            return "module \(identifier) already registered"
        case let .registration(reason):
            return "registration failed: \(reason)"
        }
    }
}
