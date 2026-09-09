import Foundation

/// One framework discovery looks at: what its bundle says about itself and
/// how to find its entry class. Real candidates come from the app's embedded
/// framework directory; the harness builds them by hand to prove every
/// refusal path without a framework on disk.
public struct BackendModuleCandidate {
    public var bundleIdentifier: String
    public var frameworkName: String
    public var shortVersion: String?
    public var buildVersion: String?
    /// The parsed manifest plist. Nil means the framework is not a module
    /// and is silently ignored.
    public var manifest: [String: Any]?
    /// Runtime class lookup by name.
    public var entryClass: (String) -> AnyClass?
    /// Whether a class was defined by this framework rather than by another
    /// image that happens to use the same name.
    public var owns: (AnyClass) -> Bool

    public init(
        bundleIdentifier: String,
        frameworkName: String,
        shortVersion: String?,
        buildVersion: String?,
        manifest: [String: Any]?,
        entryClass: @escaping (String) -> AnyClass?,
        owns: @escaping (AnyClass) -> Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.frameworkName = frameworkName
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.manifest = manifest
        self.entryClass = entryClass
        self.owns = owns
    }
}

/// The version every first-party framework must match exactly. There is no
/// compatibility range: modules ship with the app, built from the same
/// `Version.xcconfig`, and a stale one is a packaging mistake.
public struct BackendHostVersion: Equatable, Sendable {
    public var shortVersion: String
    public var buildVersion: String

    public init(shortVersion: String, buildVersion: String) {
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
    }

    public init?(bundle: Bundle) {
        guard let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { return nil }
        self.init(shortVersion: short, buildVersion: build)
    }

    var description: String { "\(shortVersion) (\(buildVersion))" }
}

/// Finds the backend modules dyld already loaded and activates them.
///
/// This is discovery, not loading: nothing is `dlopen`ed. The app links every
/// module framework as a startup dependency, dyld maps them before `main`,
/// and this walks what is mapped. A module that fails any check is logged as
/// `backend failed to bootstrap` with its identity and the reason, then left
/// out entirely — no capability, no sidebar row, no alert. The next launch
/// tries again.
@MainActor
public enum BackendModuleDiscovery {
    /// The frameworks in this app's own `Frameworks` directory that carry a
    /// module manifest, sorted by bundle identifier so registration order is
    /// a property of the package and not of dyld.
    public static func embeddedCandidates(in app: Bundle = .main) -> [BackendModuleCandidate] {
        guard let frameworks = app.privateFrameworksURL?.resolvingSymlinksInPath() else { return [] }
        var candidates: [BackendModuleCandidate] = []
        for bundle in Bundle.allFrameworks {
            let url = bundle.bundleURL.resolvingSymlinksInPath()
            guard url.deletingLastPathComponent().path == frameworks.path else { continue }
            guard let manifestURL = bundle.url(
                forResource: FilaBackendKit.manifestResourceName,
                withExtension: FilaBackendKit.manifestResourceExtension
            ) else { continue }
            let manifest = NSDictionary(contentsOf: manifestURL) as? [String: Any] ?? [:]
            candidates.append(BackendModuleCandidate(
                bundleIdentifier: bundle.bundleIdentifier ?? url.lastPathComponent,
                frameworkName: url.deletingPathExtension().lastPathComponent,
                shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                manifest: manifest,
                entryClass: { NSClassFromString($0) },
                owns: { Bundle(for: $0) == bundle }
            ))
        }
        return candidates.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    /// Validate, instantiate and register every candidate, then resolve the
    /// backends against the completed provider set.
    public static func bootstrap(
        _ candidates: [BackendModuleCandidate],
        hostVersion: BackendHostVersion,
        host: any BackendHost
    ) -> BackendRegistry {
        let registry = BackendRegistry()
        for candidate in candidates.sorted(by: { $0.bundleIdentifier < $1.bundleIdentifier }) {
            guard candidate.manifest != nil else { continue }
            do {
                try activate(candidate, hostVersion: hostVersion, host: host, into: registry)
                host.log("backend module bootstrapped: \(candidate.bundleIdentifier)")
            } catch {
                host.warn("backend failed to bootstrap: \(candidate.bundleIdentifier): \(error)")
            }
        }
        registry.resolveBackends(host: host)
        return registry
    }

    private static func activate(
        _ candidate: BackendModuleCandidate,
        hostVersion: BackendHostVersion,
        host: any BackendHost,
        into registry: BackendRegistry
    ) throws {
        let manifest = try BackendModuleManifest(plist: candidate.manifest ?? [:])
        try manifest.validate()
        let moduleVersion = BackendHostVersion(
            shortVersion: candidate.shortVersion ?? "",
            buildVersion: candidate.buildVersion ?? ""
        )
        guard moduleVersion == hostVersion else {
            throw BackendModuleError.versionMismatch(
                module: moduleVersion.description,
                host: hostVersion.description
            )
        }
        let identity = BackendModuleIdentity(
            bundleIdentifier: candidate.bundleIdentifier,
            frameworkName: candidate.frameworkName,
            displayNameKey: manifest.displayNameKey
        )
        guard let entryClass = candidate.entryClass(identity.entryClassName) else {
            throw BackendModuleError.entryClassMissing(identity.entryClassName)
        }
        guard candidate.owns(entryClass) else {
            throw BackendModuleError.entryClassForeign(identity.entryClassName)
        }
        guard let moduleType = entryClass as? any BackendModule.Type else {
            throw BackendModuleError.entryClassNotConforming(identity.entryClassName)
        }
        let entry = moduleType.init()
        let registration = BackendRegistration(module: identity, host: host)
        do {
            try entry.register(with: registration)
        } catch let error as BackendModuleError {
            throw error
        } catch {
            throw BackendModuleError.registration(String(describing: error))
        }
        try registry.commit(registration, entry: entry)
    }
}
