import Foundation

/// The static description a module framework ships in `FilaBackendModule.plist`.
///
/// It describes the packaged module, not a saved connection: schema version,
/// the host contract the module was compiled against, and the key of its
/// display name. Bundle identity comes from `CFBundleIdentifier` and the
/// entry class from the framework name, so neither is repeated here where it
/// could drift.
public struct BackendModuleManifest: Equatable, Sendable {
    public static let schemaKey = "FilaBackendModuleSchema"
    public static let contractKey = "FilaBackendContract"
    public static let displayNameKey = "FilaBackendDisplayName"

    public let schemaVersion: Int
    public let contractVersion: Int
    public let displayNameKey: String

    public init(schemaVersion: Int, contractVersion: Int, displayNameKey: String) {
        self.schemaVersion = schemaVersion
        self.contractVersion = contractVersion
        self.displayNameKey = displayNameKey
    }

    public init(plist: [String: Any]) throws {
        guard let schema = plist[Self.schemaKey] as? Int else {
            throw BackendModuleError.manifest("\(Self.schemaKey) missing or not an integer")
        }
        guard let contract = plist[Self.contractKey] as? Int else {
            throw BackendModuleError.manifest("\(Self.contractKey) missing or not an integer")
        }
        guard let name = plist[Self.displayNameKey] as? String, !name.isEmpty else {
            throw BackendModuleError.manifest("\(Self.displayNameKey) missing or empty")
        }
        self.init(schemaVersion: schema, contractVersion: contract, displayNameKey: name)
    }

    /// Refuse before the entry class is touched.
    public func validate() throws {
        guard schemaVersion == FilaBackendKit.manifestSchemaVersion else {
            throw BackendModuleError.schemaMismatch(schemaVersion)
        }
        guard contractVersion == FilaBackendKit.contractVersion else {
            throw BackendModuleError.contractMismatch(contractVersion)
        }
    }
}
