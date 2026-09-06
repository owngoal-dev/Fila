import Foundation

enum AppSort: String, CaseIterable {
    case name, identifier

    var title: String {
        switch self {
        case .name: return String(localized: "Name")
        case .identifier: return String(localized: "Bundle Identifier")
        }
    }
}

/// Where the app was installed from: the user's apps live in per-app bundle
/// containers, the system's under `/Applications`.
enum AppScope: String, CaseIterable {
    case all, user, system

    var title: String {
        switch self {
        case .all: return String(localized: "All Apps")
        case .user: return String(localized: "User Apps")
        case .system: return String(localized: "System Apps")
        }
    }

    func includes(_ app: InstalledApp) -> Bool {
        switch self {
        case .all: return true
        case .user: return app.isUserApp
        case .system: return !app.isUserApp
        }
    }
}

extension InstalledApp {
    var isUserApp: Bool { bundlePath.contains("/Bundle/Application/") }
}
