import Foundation

/// The contract every bundled backend module is built against.
///
/// FilaBackendKit is Foundation only. It names the module entry point, the
/// registration a module fills in at startup, the registry the app keeps, and
/// the small values a backend and the shell exchange. It imports no vendor
/// library, no XPC and no UIKit, so a module framework depends on it without
/// dragging in anything it did not ask for.
public enum FilaBackendKit {
    /// The version of this contract. A module's manifest names the version it
    /// was compiled against; discovery refuses a module whose number differs
    /// before its entry class is ever touched. Bump it when `BackendModule`,
    /// `BackendHost` or `BackendRegistration` change shape.
    ///
    /// 2: the host supplies a credential store and takes backends added
    /// and removed after bootstrap; a registration may name a connection
    /// setup.
    ///
    /// 3: a root names the app's artwork rather than an SF Symbol and may
    /// carry a detail line; a connection setup names its list heading.
    public static let contractVersion = 3

    /// The manifest format itself. Independent of the host contract so a
    /// manifest key can be added without pretending the module ABI changed.
    public static let manifestSchemaVersion = 1

    /// The file inside a module framework's bundle whose presence says
    /// "this framework is a backend module". Shared UI, contracts and vendor
    /// frameworks do not carry it, which is how discovery tells them apart.
    public static let manifestResourceName = "FilaBackendModule"
    public static let manifestResourceExtension = "plist"
}
