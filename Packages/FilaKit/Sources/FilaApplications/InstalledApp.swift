import Foundation

/// One installed application as the installation database describes it.
public struct InstalledApp: Hashable, Sendable {
    public var name: String
    public var bundleIdentifier: String
    public var bundlePath: String
    /// Nil when the app has no data container of its own, and also when the
    /// fallback source found it — see `ApplicationCatalog.scanBundleContainers`.
    public var dataPath: String?
    /// The installation database owns group identifiers and their container URLs.
    public var groupPaths: [String: String] = [:]
    /// Facts the installation database states about the app, in display
    /// order, as localized label and value. Empty for the fallback scan.
    public var details: [Detail] = []

    public struct Detail: Hashable, Sendable {
        public var label: String
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public init(
        name: String,
        bundleIdentifier: String,
        bundlePath: String,
        dataPath: String?,
        groupPaths: [String: String] = [:],
        details: [Detail] = []
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.dataPath = dataPath
        self.groupPaths = groupPaths
        self.details = details
    }

    /// The first candidate name with a visible character; failing all, the
    /// last component of the identifier, so `com.apple.MediaRemoteUI` reads as
    /// `MediaRemoteUI`. LaunchServices hands back a lone U+200E for some
    /// system apps, which is why format characters count as empty here.
    public static func name(_ candidates: String?..., identifier: String) -> String {
        let blank = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        for candidate in candidates {
            let name = candidate?.trimmingCharacters(in: blank) ?? ""
            if !name.isEmpty {
                return name
            }
        }
        return String(identifier.split(separator: ".").last ?? Substring(identifier))
    }

    /// The user's apps live in per-app bundle containers, the system's under
    /// `/Applications`.
    public var isUserApp: Bool {
        bundlePath.contains("/Bundle/Application/")
    }

    /// Where an app keeps its bytes: bundle, data container, then each group.
    public var locations: [Location] {
        var locations = [Location(kind: .bundle, path: bundlePath)]
        if let path = dataPath {
            locations.append(Location(kind: .data, path: path))
        }
        locations += groupPaths.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { Location(kind: .group($0.key), path: $0.value) }
        return locations
    }

    public struct Location: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case bundle, data, group(String)
        }

        public let kind: Kind
        public let path: String
    }
}

public enum AppSort: String, CaseIterable, Sendable {
    case name, identifier
}

/// Where the app was installed from: the user's apps live in per-app bundle
/// containers, the system's under `/Applications`.
public enum AppScope: String, CaseIterable, Sendable {
    case all, user, system

    public func includes(_ app: InstalledApp) -> Bool {
        switch self {
        case .all: true
        case .user: app.isUserApp
        case .system: !app.isUserApp
        }
    }
}
