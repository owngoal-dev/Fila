import Foundation

enum AppSort: String, CaseIterable {
    case name, identifier

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .identifier: String(localized: "Bundle Identifier")
        }
    }
}

/// Where the app was installed from: the user's apps live in per-app bundle
/// containers, the system's under `/Applications`.
enum AppScope: String, CaseIterable {
    case all, user, system

    var title: String {
        switch self {
        case .all: String(localized: "All Apps")
        case .user: String(localized: "User Apps")
        case .system: String(localized: "System Apps")
        }
    }

    func includes(_ app: InstalledApp) -> Bool {
        switch self {
        case .all: true
        case .user: app.isUserApp
        case .system: !app.isUserApp
        }
    }
}

extension InstalledApp {
    var isUserApp: Bool {
        bundlePath.contains("/Bundle/Application/")
    }
}
