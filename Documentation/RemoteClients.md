# Extensible backends, UI and SMB/FTP clients

2026-09-09 — agreed architecture with implementation details to verify. The executable phase plan is [BackendModularisation-Plan.md](BackendModularisation-Plan.md). No runtime interface, dependency or XPC operation has been implemented. Library observations describe inspected upstream sources, not a pinned or tested build.

## Decisions

- SMB uses **kishikawakatsumi/SMBClient**; FTP uses **libcurl**. Both have permissive licenses. AMSMB2/libsmb2 are excluded.
- Extract a shared app-side file-service contract for browsing, content transfer and directory invalidation. Local storage, SMB and FTP implement it.
- Each logical backend owns its bookmarks, history, location preferences and sidebar contribution through an injected preference storage. A disconnected backend still exists and can publish saved locations.
- Preserve specialized local operations beneath that boundary: descriptors, root access, POSIX metadata, local trash and daemon jobs.
- Service-to-client updates are directory subscriptions. An event means “reload this directory,” not “apply this exact mutation.”
- Deliver connection setup, browsing, snapshot previews and basic file operations including cross-backend copy/move. Upload/download are transport steps inside those operations. Prove destination publication and source cleanup before shipping moves.
- Backend modules are bundled dynamic frameworks linked into the app at startup. There is no third-party installation or external module search. Each framework carries a static manifest; main discovers its entry class by framework-name convention and activates it.
- Modules/backends are not hot-unloaded. All packaged modules are enabled automatically, with no user enable/disable switch. A bootstrap failure disables its contribution for that launch and remains visible only in logs.
- One SMB share or FTP starting directory is one backend instance. Local roots use built-in defaults: Documents in the sandbox, the appropriate existing full-local root/locations otherwise. No additional user-created local roots.
- Sidebar collects contributions into shared sections; no cross-section drag ordering. Applications and Music provide no favorites. Only global appearance and history-recording policy are shared preferences; other feature preferences belong to each backend.
- Inject `DefaultStorage` (implemented by UserDefaultsStorage) for backend preferences. App/extensions keep separate preference domains; no cross-process preference sharing or sync.
- Cross-backend file copy and move are in scope. The user sees those ordinary operations while transfer adapters perform any required download/upload. Domain-specific application/music operations stay typed and explicit.

## Current architecture

`FilaClient.FileService` is an internal local-backend protocol implemented by `DaemonFileService` and `LocalFileService`. Its signatures depend on `DaemonLink.Hello`, `DirectoryPage`, descriptor flags, POSIX attributes and job IDs. Its general name hides a specialized contract.

The current system already has reverse channels: unsolicited XPC messages become `DaemonLink.jobEvents` and `searchResults`. These carry work progress/results, not directory observations. `OperationCenter.finish` posts `.filaJobFinished`, which browser controllers use to reload affected paths.

`FilaRemote.RemoteFileService` serves local storage to the WebDAV **server**. It is not an outbound client and remains a separate contract.

Code references: [local contract](../Packages/FilaKit/Sources/FilaClient/FileService.swift), [reverse channels](../Packages/FilaKit/Sources/FilaClient/DaemonLink.swift), [directory pagination](../Fila/Services/Files/DirectoryReader.swift), [completion notifications](../Fila/Services/Transfers/OperationCenter.swift), [publication policy](../Fila/Services/Transfers/OperationCenter+Download.swift).

## Ownership and dependencies

| Owner | Responsibility | Dependencies |
| --- | --- | --- |
| New `FilaBackendKit` target | Backend/file-service contracts, typed preference-storage contract and location/sidebar values | Foundation only |
| New `FilaLocal` | Local backend classes, neutral local-access contract and in-process implementation | Public shared contracts and audited local file operations |
| `FilaPrivileged` dynamic target | Daemon/XPC and full-build local backend selection extracted from FilaClient | Implements shared local-access contracts; absent from sandbox composition |
| `FilaSMB` / `FilaFTP` dynamic targets | Separate SMB/FTP modules and connection lifetimes | `FilaBackendKit` plus their respective vendor library |
| App services | Backend composition, UserDefaults/Keychain adapters, sidebar aggregation, staging and `OperationCenter` | Injects dependencies; does not own each backend's bookmark rules |
| Interface | Lists, subscriptions, actions and previews | Shared contract for common behavior; local capabilities where necessary |

Implementations depend on `FilaBackendKit`; the shared contract imports no vendor library, XPC or UIKit. New backend/UI targets do not enter filad's dependency graph. Core model code builds on the macOS test host; UIKit/native feature implementations are iOS-only.

Rename the current internal `FilaClient.FileService` and its file to `LocalFileAccess` when extracting the shared protocol. Preserve wire values and persisted keys. `DaemonLink` continues choosing between the two local backends; it does not choose remote hosts or resolve credentials.

Reserve `LocalFileBackend` for the extensible, long-lived app-side class implementing `FileBackend`; `LocalFileAccess` names its specialized local-operation dependency. Inject preferences into that logical backend, never into filad or the XPC transport. `SandboxedLocalFileBackend` is a thin subclass of this class, not of the daemon transport.

Move local result declarations out of the large `DaemonLink` implementation file into owner-aligned model files where needed, preserving nested typealiases only for actual source compatibility. Do not move POSIX/wire models into the shared target just to make everything look uniform.

The shared local implementation must own meaningful adaptation: metadata mapping, paged-list collection, observation and content copying. It must not forward every local method through another facade. Existing root-specific callers continue using their specialized API.

## Bundled frameworks and automatic startup discovery

Confirmed decisions: all modules ship with the app, dyld loads their Mach-O images as startup dependencies, main automatically discovers/activates them, every backend module has a static manifest, and Local/Privileged/SMB/FTP/Applications/Music are separate dynamic frameworks. FilaBackendUI is the shared UI framework, and Application/Music ship their full feature UI inside their respective modules. All first-party frameworks ship at exactly the app version/build. This replaces the earlier idea of loading framework code on first use. Network connections and catalog queries remain demand-driven.

```text
App executable load commands
          |
          v
dyld loads linked, bundled frameworks before main
          |
          v
main -> BackendModuleDiscovery
          |
          +-- find loaded frameworks in this app's Frameworks directory
          +-- identify modules by their static manifest
          +-- derive entry-class name from framework name
          +-- validate entry class and common contract
          `-- instantiate and register using BackendHost
                         |
                         v
                   BackendRegistry
                         |
                         +-- backend factories / saved instances
                         +-- connection-setup entry points
                         `-- screen factories / typed feature integration
```

### Module names and entry classes

| Framework | Objective-C runtime entry name | Backend family |
| --- | --- | --- |
| `FilaLocal.framework` | `FilaLocalModule` | LocalFileBackend / SandboxedLocalFileBackend |
| `FilaPrivileged.framework` | `FilaPrivilegedModule` | Privileged-aware local access provider; no duplicate local sidebar root |
| `FilaSMB.framework` | `FilaSMBModule` | SMBBackend |
| `FilaFTP.framework` | `FilaFTPModule` | FTPBackend |
| `FilaApplications.framework` | `FilaApplicationsModule` | ApplicationBackend |
| `FilaMusicLibrary.framework` | `FilaMusicLibraryModule` | MusicLibraryBackend |

Use exactly `<framework basename>Module` as the discovery convention. Each entry is a non-generic NSObject subclass with an explicit Objective-C runtime name and conforms to the shared BackendModule protocol. A runtime name lookup resolves it after dyld loading; validate the conformance and that the class belongs to that framework before instantiation. The app does not import individual entry classes or maintain a hard-coded registry switch.

`BackendModuleDiscovery` is the name of the discovery owner, not BackendModuleLoader: it does not dlopen unlinked code. `BackendRegistry` owns successful registrations. `BackendHost` supplies scoped preference/credential access, task reporting and navigation/preview facilities. `BackendModule` defines the initializer and explicit registration entry point. These contracts live in one shared `FilaBackendKit.framework`, linked once by host/modules, not statically copied into every framework.

Registration builds factories and lightweight contributions only. Do not connect to servers, enumerate installed applications/music, create view controllers or request user authorization inside module constructors or registration. main's existing main-actor entry performs registration before UIApplicationMain; scene-dependent work waits for application/UI initialization. Module bootstrap diagnostics stay in developer logs, not app alerts or rows. Avoid Objective-C +load and Swift global initializers as registration mechanisms.

Collect provider registrations first, then resolve backend factories against the completed host registry. FilaPrivilegedModule supplies the privileged-aware local-access provider; FilaLocalModule supplies the common local backend classes and in-process provider. They do not race to register two sidebar roots with the same ID. Factory requirements determine availability after registration, independent of framework enumeration order.

Keep bootstrap failure separate from service readiness. An on-demand daemon that has not answered is not a module bootstrap failure and retains the existing Connecting/grace behavior. A failed privileged module must not silently demote a full-filesystem root to a different access mode; omit backends whose required provider failed. Successfully bootstrapped SMB/FTP authentication, connection and operation errors retain their normal user-facing recovery. Ordinary errors do not permanently unregister the module.

### Static manifest

Place `FilaBackendModule.plist` in each backend framework's bundle. Its presence distinguishes modules from shared UI, contracts and third-party frameworks. Initial fields are manifest schema version, supported host-contract version and a localized display-name resource key. Bundle identity comes from CFBundleIdentifier; entry-class identity comes from the naming convention. Do not duplicate either in an independently editable field or invent a heuristic class-name search fallback.

The manifest describes the packaged module, not saved server connections, passwords or mutable availability. Its version fields permit rejecting a mismatched module before invoking registration. Modules must ship with the exact same app marketing version and build number, generated from Configuration/Version.xcconfig. Compare CFBundleShortVersionString and CFBundleVersion to the host before entry-class instantiation/registration; do not duplicate them as independently maintained manifest fields. Build first-party modules together with the same toolchain/shared contracts. There is no independent module update, cross-release compatibility range or plugin ABI promise. Verify the shared frameworks at packaging time as well, since dyld can fail before runtime checks.

Enumerate loaded framework bundles, restrict discovery to this app's embedded framework directory, and select those with the manifest. Discovery scans metadata/class names, not the filesystem outside the bundle or arbitrary runtime classes. Sort deterministically before registration; sidebar order remains its own presentation preference, not dyld image order. A missing entry, version/contract mismatch or duplicate registration produces the log message `backend failed to bootstrap` with module ID and diagnostic reason, and no partial registrations. Backend registration calls commit only after the module's registration succeeds.

This is deterministic convention-based discovery: adding a backend means adding its framework target/embed/link configuration, manifest and entry class. main and the sidebar require no new backend-specific branch. There is no plugin installation UI, unsigned module support or external framework directory.

### Link, embed and signing contract

Copying a framework into the bundle is insufficient: the app must retain a non-weak startup load dependency for every included backend. Since the host does not statically reference entry-class symbols, the linker may otherwise discard an unused framework dependency. The local Apple linker documents `-needed_framework` for retaining a framework even when none of its symbols are referenced. Use a supported retention setting and verify the resulting Mach-O load commands rather than trusting project membership.

Every included module and its transitive frameworks must be embedded, signed and audited for the iOS floor. The sandbox app must neither embed nor link FilaApplications/FilaMusicLibrary or their private dependencies. Shared FilaLocal registers the suitable local implementation from injected authority; it must not pull full-only integration into the sandbox binary.

A missing/incompatible strongly linked framework can fail in dyld before main. Discovery cannot isolate that failure; packaging/build verification must prevent it. Manifest/class/registration failures are recoverable at the discovery boundary: log `backend failed to bootstrap`, skip that module and publish none of its capabilities or UI. No alert, toast, failed-module row or placeholder is shown in the app. Dynamic frameworks run in the same app process and do not isolate crashes or confer extra privilege.

Add integration proofs: each included module is visible to discovery before first use; class lookup succeeds in optimized builds; unused-library stripping does not remove startup dependencies; third-party/support frameworks are ignored; duplicate IDs cannot partially overwrite the registry; and sandbox artifacts contain neither excluded modules nor their load commands. Loaded module images are never unloaded, and closing a page or the last subscription never unloads its backend. Retain bootstrapped module/backend owners for their configured lifetime; connections and per-view watch resources may close independently. Do not implement dlclose, module hot reload or a user module switch. All packaged modules bootstrap automatically once per launch. A failed bootstrap disables registration for that launch without persisting an isEnabled flag; the next launch tries the packaged module again. These tests establish the selected startup contract without independent module updates.

## Backend-owned preferences and sidebar composition

Extracting queries alone is insufficient. Today `AppPreferences` owns favorites, recent directories, per-folder layouts and local sidebar presets; `SidebarViewController` reads those global values and separately fetches local mounts. A new backend would have to change those consumers again. Move ownership of source-specific user data to the corresponding logical backend.

A **backend** is the long-lived storage source identified by a stable ID. A **file service** is its I/O implementation/session. `LocalFileBackend` owns the local source; each configured SMB share or FTP root owns its own backend instance. Disconnecting retires network resources, not the backend or its bookmarks. Sidebar collection must not connect to every saved server.

| Data | Owner |
| --- | --- |
| Favorites, recent directories, last directory, per-directory layout | Backend; persisted through its injected storage |
| Local filesystem presets, mount locations, bootstrap/trash locations | LocalFileBackend, derived from local capabilities and preferences |
| Remote root and saved remote locations | That remote backend, available while offline |
| Global appearance and history-recording switch | App preferences; all backends observe the common policy |
| Navigation tabs and derived sidebar section ordering | Shell-owned navigation/presentation state, not shared backend feature preferences |
| Applications and Music roots, lists, preferences and special actions | ApplicationBackend and MusicLibraryBackend, respectively |
| Settings and task controls | App shell; not filesystem or catalog backends |
| Connection profile list and secret access | App composition/profile storage and injected credential access; secrets stay out of preference snapshots |

Keep UserDefaults as the production persistence mechanism. Inject a scoped storage rather than letting backends reach for `UserDefaults.standard` or `AppPreferences.shared`. The storage translates persisted keys/encoding; the backend owns defaults, ordering, deduplication, limits and update behavior.

An illustrative DI contract (`DefaultStorage` is the agreed abstraction name):

```swift
@MainActor
protocol DefaultStorage<Value> {
    associatedtype Value: Codable
    func load() throws -> Value?
    func save(_ preferences: Value) throws
}

let local = LocalFileBackend(files: localFiles, preferences: localPreferences)
let nas = SMBBackend(profile: nasProfile, preferences: nasPreferences, credentials: credentials)
```

`localPreferences` and `nasPreferences` are separately scoped UserDefaults-backed stores injected by app composition. Tests inject isolated storage. `FileBackendPreferences` is the typed saved value for file bookmarks/history/folder preferences; ApplicationPreferences and MusicLibraryPreferences carry their own domain settings through the same generic storage contract. The saved value does not contain connected status, timers, sidebar rows, vendor handles or a second copy of the profile. Preserve absent versus explicitly empty values so default favorites do not reappear after a user removes them.

The storage returns absence/decoded values without deciding which default locations a backend should expose. A failed decode preserves the stored input and reports a recoverable load failure; it must not silently overwrite all bookmarks with defaults. The backend serializes mutations on the main actor, submits the next preferences to storage, then publishes the resulting sidebar snapshot. A failed save retains the prior visible state and reports the error. UserDefaults accepting an update is not a promise of synchronous disk durability.

Initial source-related UI state stays on the main actor; network work does not. Store the loaded preferences once in the backend and derive sidebar sections from that authority. Storage is persistence, not another observable copy. All in-app writes to a scope go through its backend. App and extension/process preferences are deliberately separate. Each process injects its own UserDefaults domain plus backend scope through DefaultStorage. Do not share backend preferences through an App Group defaults suite or add cross-process synchronization. Existing shared file containers remain a separate feature.

Expose backend data, not UIKit cells or prebuilt menus. The first backend-facing interface can be:

```swift
@MainActor
protocol Backend: AnyObject {
    var id: BackendID { get }
    var root: BackendRoot { get }
    func sidebarUpdates() -> AsyncStream<BackendSidebar>
}

@MainActor
protocol FileBackend: Backend {
    func setFavorite(_ path: ServicePath, included: Bool) throws
    func recordVisit(_ path: ServicePath) throws
    func fileService() async throws -> any FileService
}
```

`fileService()` owns lazy connection/reconnection and returns the shared I/O contract; it is not required to obtain saved sidebar data. `recordVisit` is called after successfully opening a directory, not by background enumeration. Add remove-history/reorder/layout methods when migrating their existing callers, retaining backend ownership rather than exposing mutable arrays to controllers.

`BackendSidebar` is a complete immutable contribution: available locations plus supported favorite/recent records. ApplicationBackend and MusicLibraryBackend contribute their roots without favorite records; their commands and preferences have no favorite feature. Each row has backend-scoped identity and a `BackendLocation`; file locations additionally carry their typed ServicePath. The app maps semantic kinds to icons/localized UI. Snapshot rows are projections, not persisted records. Different sections can show the same location, so final UI identity includes section/role as well as backend and item identity.

The stream yields an initial snapshot immediately from loaded preferences, then a replacement snapshot when those preferences or backend-derived locations change. Each subscriber has its own stream with `bufferingNewest(1)`: dropping an older complete snapshot loses no final state. Backend sidebar streams survive network disconnection; directory observation streams retain their separate failure/lifetime rules. Neither stream is multiplexed into job progress.

One app-side `SidebarModel` subscribes to registered backends, keeps their latest contributions keyed by ID and derives the combined sidebar. It emits available contributions incrementally; it does not await every backend or combine them behind an all-success barrier. This cache is the projection needed to combine streams, not a second bookmark store. A changed backend replaces only its own contribution.

Registration/removal updates the contributor set. Cancel the removed subscription, discard its contribution and reject late updates from its retired instance before reusing an ID. Initial updates and subsequent updates must retain configured backend order, never completion-arrival order. Collect filesystem favorites into the shared Favorites section and places into the shared Places section, preserving deterministic contributor order and each backend's own ordering. Cross-section drag/reordering is unsupported; do not persist a global interleaving of unrelated section items. Existing within-section ordering can migrate through its owning backend; arbitrary cross-backend reordering is not implied. ApplicationBackend and MusicLibraryBackend provide their own root entries through the same merge. Settings/task controls remain shell-owned.

For a unified chronological Recents section, each new visit stores a timestamp in its owning backend. Merge by timestamp with stable backend/item tie-breaking and deduplicate by full `BackendLocation`, not an unqualified item ID or path alone. Legacy local recents have only an ordered path array: preserve that order as undated history; do not invent current timestamps. Dated visits precede undated records. Retain the local 40-record storage cap initially and a bounded global display limit; no cross-backend history database is needed.

Global “record recents” remains one app policy. The app applies it to every backend, including offline instances; disabling it clears each backend's history and prevents subsequent recording. Do not copy independently mutable versions of the switch into each backend's saved state. Keep global appearance (such as theme) global. Sort key/direction, hidden-file visibility, default list/grid layout and per-folder layout overrides belong to each backend. Application sort/scope and music-specific options likewise stay in their respective preference scopes. A backend's local root/trash policies never apply to remote roots.

## Preference scopes and migration

- The existing full-filesystem local preference scope is a fixed logical identity, independent of whether DaemonLink selected root or in-process access. Grace-period resolution must not swap bookmark stores. The sandboxed container root has its own stable root/backend scope; it cannot reinterpret absolute full-filesystem bookmarks as container-relative paths.
- Remote scopes use stable profile IDs, not hostnames, passwords, display names or connection-object identity. Two accounts/shares on one host must not collide. Preserve settings across reconnect and display-name/credential changes.
- Changing the host/share/root to another namespace creates a new backend identity by default. Rebinding existing bookmarks requires an explicit migration decision; an edit must not silently point saved paths at another filesystem.
- The UserDefaults adapter for local storage retains existing keys and representation where possible: `favorites`, `recents`, `recentFiles`, `lastDirectory`, `folderLayouts`, `presetOrder` and `hiddenPresets`. Preserve preset raw values and the existing legacy recent-file filtering. Add visit timestamps as compatible additional metadata rather than rewriting the path array unnecessarily.
- New remote scopes can use a versioned record under a profile-specific key. These are persisted preferences, never credentials. The storage scope prevents read-modify-write of one backend from replacing another's record.
- Instantiate storage in one composition root, inject it, and migrate all favorites/history callers off AppPreferences. Transitional forwarding is temporary: delete it when consumers are moved, leaving a single owner.
- Disconnect preserves saved data. Removing a profile removes its scoped saved data through the existing explicit profile-removal flow; deleting one favorite never deletes or renames a file.

Favorites remain visible when a server is offline or permission is denied. Do not drop remote history because a timeout resembles a missing path. Listing failure and preference failure are independent; a failing SMB server must not hide local locations or another backend's bookmarks.

## Backend and controller class plan

Applications and the music library are catalog backends, not file backends. They reuse root identity, injected typed storage, sidebar contribution and list-update lifecycle without implementing file descriptors, chmod, archive extraction or directory traversal. `Backend` is the shared protocol; `FileBackend` refines it for local/FTP/SMB sources. Avoid an abstract superclass containing optional state for all domains.

### Backend names and responsibilities

| Proposed type | Kind / relationship | Owns |
| --- | --- | --- |
| `Backend` | Main-actor protocol | Stable ID, BackendRoot and independent sidebar snapshot subscriptions |
| `FileBackend` | Protocol refining Backend | File favorites/history commands and obtaining a FileService |
| `LocalFileBackend` | Non-final class conforming to FileBackend | Local root, injected FileBackendPreferences storage and local I/O adaptation |
| `SandboxedLocalFileBackend` | Final subclass of LocalFileBackend | Container-root configuration and in-process-only local authority |
| `SMBBackend` | Final class conforming to FileBackend | One saved SMB share, file preferences and lazy SMB service |
| `FTPBackend` | Final class conforming to FileBackend | One saved FTP root, file preferences and lazy libcurl service |
| `ApplicationBackend` | Final class conforming to Backend | Installed applications, application preferences, root/sidebar data and application actions |
| `MusicLibraryBackend` | Final class conforming to Backend | Library tracks, music preferences, root/sidebar data and music actions |
| `SidebarModel` | Main-actor class | Registration/subscriptions and derived combined sidebar; no domain storage |
| `UserDefaultsStorage<Value>` | Concrete DefaultStorage implementation | Scoped encoding/key compatibility for one backend's typed preferences |

`ApplicationBackend` receives `InstalledAppCatalog`, `ApplicationIconRenderer`, the current IPA installation service and `DefaultStorage<ApplicationPreferences>` as appropriate to its real operations. Remove direct static/global access at its consumers. It owns app sort/scope (preserving `appSort` and `appScope`), list refresh and installed-app lookup. Expose explicit operations such as application listing, opening an app, locating its bundle/data containers, and installation through the existing installation owner. Do not invent uninstall functionality solely to fill an action interface.

`MusicLibraryBackend` receives `MusicLibraryEditor` and `DefaultStorage<MusicLibraryPreferences>`. The existing editor/native bridge remains the owner of low-level library work. The backend owns track listing/subscription and explicit import, export, delete and metadata editing actions. MusicLibraryTrack's persistent ID remains identity; titles, album names and file paths do not replace it. Keep the existing protected/cloud-track export restrictions. Avoid storing a second track database or repeating the editor's change verification.

Application IDs are bundle identifiers; music IDs are persistent library IDs. `BackendLocation` contains a backend ID and an opaque backend-owned item identity, including a root identity. `FileLocation` remains a typed file specialization convertible at the navigation/sidebar boundary. The shell must not parse application IDs as paths or know a global enum case for every future backend. BackendRoot now represents a catalog root as well as a filesystem root.

ApplicationBackend and MusicLibraryBackend expose typed lists and independent invalidation streams for their catalog roots. Reuse the same subscription/coalescing implementation and initial-event contract, not the filesystem `FileService` protocol. Music library notifications feed MusicLibraryBackend; application refresh uses existing lifecycle/installation signals initially. Neither is forced to poll like FTP. Do not duplicate current NotificationCenter observers in controllers after moving them into these owners.

Sidebar snapshots and preferences remain usable without loading the full app/music catalog. Query catalog contents only when the corresponding screen or another real consumer asks. Per-backend data loading errors cannot prevent the shell's initial sidebar.

### UI class hierarchy

| Proposed controller | Relationship / migration | Owns |
| --- | --- | --- |
| `BackendListViewController<Item>` | Generic UIViewController base with a UICollectionView | Shared subscription task, reload ownership, loading/empty/error presentation, stable item identity/diffs and selection/search chrome |
| `FileBrowserViewController` | Subclass for FileEntry; rename/migrate current BrowserViewController | File rows/grid, breadcrumbs, directory navigation and file-specific menus |
| `ApplicationListViewController` | Subclass for InstalledApp; migrate AppListViewController | App cells, app scope/sort controls and navigation to details |
| `MusicLibraryViewController` | Subclass for MusicLibraryTrack; migrate current table list to shared collection list | Track cells, music search and track actions |
| `ApplicationDetailViewController` | Rename AppDetailViewController, keep feature-specific detail behavior | Rendering application details and invoking ApplicationBackend actions |
| `MusicTrackViewController` | Retain feature-specific detail controller | Track metadata UI and invoking MusicLibraryBackend actions |
| `SidebarViewController` | Retain, inject SidebarModel | Render merged contributions and dispatch typed destinations |

There are no Local/SMB/FTP-specific browser-controller subclasses. All use FileBrowserViewController with a different injected FileBackend. The sandboxed local backend uses that same controller. Application and music lists specialize UI because their actual item presentation/actions differ, not because their protocols need a new transport-specific screen.

Keep base-class hooks limited to row configuration, loading/subscription inputs, selection and genuinely different controls. The base must not contain app/music/file switches, global preferences, or generic string-command dispatch. Subclasses present confirmations and then call concrete typed backend operations; backends expose no UIAlertController/UIAction objects. Reuse the existing OperationCenter when those operations produce user-visible tasks.

Preserve the local file browser's streamed first load and complete-refresh behavior in the shared reload machinery. Do not erase incremental loading by requiring every subclass to return one complete array. Finalize the loader hook from the current DirectoryReader and catalog consumers during extraction; no new backend-specific loading loop should survive beside the base implementation. Snapshot identity is stable item ID, not an entire mutable metadata value.

The app composes a `BackendScreenFactory` closure/typealias per registered backend. It receives a BackendLocation and produces the appropriate root/detail navigation using that feature's types. Discovered module entry classes register their factories during startup activation. The shell routes by backend ID; it does not import ApplicationBackend or MusicLibraryBackend to switch on concrete classes. Do not create a separate generic router hierarchy for a registration map and a closure.

### Module and IPA exclusion plan

| Proposed target/module | Contents | Full build | Sandboxed IPA |
| --- | --- | --- | --- |
| `FilaBackendKit` | Foundation-only contracts, roots, locations and typed preference values | Yes | Yes |
| `FilaLocal` | Shared local backend classes and public-API in-process access | Yes | Yes |
| `FilaPrivileged` | Daemon/XPC selection and full local access extracted from FilaClient | Yes | **No compile, link or embedding** |
| `FilaSMB` | SMBBackend and SMBClient | Yes | Yes |
| `FilaFTP` | FTPBackend and libcurl/TLS build | Yes | Yes |
| `FilaBackendUI` | BackendListViewController, shared cells/components and public presentation contracts | Yes | Yes |
| Common app shell | Navigation, sidebar composition, OperationCenter and common viewer integration | Yes | Yes |
| `FilaApplications` | ApplicationBackend, installed-app discovery/icon/installation integration and application controllers | Yes | **No compile, link or embedding** |
| `FilaMusicLibrary` | MusicLibraryBackend, MusicLibraryEditor/NativeMusicLibrary and music-library controllers | Yes | **No compile, link or embedding** |

The new `FilaLocal` extraction is now a requirement: LocalFileBackend's base class cannot import FilaPrivileged or private feature modules. FilaLocal has no direct or transitive dependency on FilaPrivileged; the dependency direction is FilaPrivileged toward the public local contracts. Inject an access implementation through a public local-access contract. Keep the actual syscall/job behavior shared in FilaFileOps; isolate XPC-specific dependencies and audit its transitive graph rather than assuming an in-process call is public-API-only. Native iOS-only implementations remain isolated from host-testable model logic. Ordinary audio-file playback remains a common viewer feature; excluding MusicLibraryBackend does not exclude all media playback.

Use two explicit composition targets/schemes in the hand-maintained project: existing **Fila** for full builds, and proposed **FilaSandboxed** for the ordinary sandboxed IPA. Full composition embeds/links Local, Privileged, SMB, FTP, Applications and Music modules; discovery activates their registrations when runtime capability permits. Sandboxed composition embeds/links Local, SMB and FTP; discovery activates SandboxedLocalFileBackend and remote factories without referencing/importing Privileged, Applications or Music modules. Only the composition and dependency graph differ; do not fork shared screens or add per-file packaging flags.

This is the user's explicit revision of the earlier “one app binary, four wrappers” rule for the ordinary IPA. Deb and tipa retain full composition and runtime daemon/local resolution. `make ipa` selects FilaSandboxed; `make packages` builds both compositions at one build number into separate DerivedData directories. Version remains in Version.xcconfig, projects remain hand-maintained, and the existing app-group/File Provider contract remains required. The `FilaSandboxed` target and scheme exist; SMB and FTP join both compositions when their modules are built.

Moving private code out of `Fila/` is necessary because its synchronized source group currently adds files to the app automatically. Audit all indirect callers: app-folder display hooks, icon renderers, navigation links, installation flows, Objective-C bridges and private frameworks. Common code accepts optional injected decoration/navigation capabilities; it must not retain hidden references to excluded modules. Saved destinations belonging to a module that failed bootstrap are not mounted or shown; retain their persisted state for a later successful startup. Restore an available tab/root without reinterpreting those IDs as local paths, and log the skipped restoration. This silent module policy does not suppress errors from a successfully bootstrapped backend during normal use.

The sandboxed IPA verification must inspect actual linked/embedded modules, symbols, private selector/class references, resources and entitlements, with app/music feature absence as a release gate. Runtime feature hiding and an empty registration list are insufficient. Full-build tests must also prove those features remain registered and functional after extraction.

Application and music modules include their root lists, detail controllers, dedicated confirmation/input flows and resource catalogs. They depend on FilaBackendUI for the base controller/common components. FilaBackendUI depends only on public shared contracts/UI dependencies and never imports those feature modules or FilaPrivileged. Discovery registers each module's screen factories, so the shell remains independent of their concrete UI classes. Resource lookup uses the owning framework bundle.

All first-party module frameworks, FilaBackendKit and FilaBackendUI must have the exact app version/build. Third-party dependencies retain their own upstream versions. Release packaging rejects any stale first-party framework; runtime discovery also rejects mismatched backend entries without showing them. A startup log records the reason without credentials or other secrets.

## Backend roots and sandboxed local specialization

Each logical backend exposes one immutable `BackendRoot`. The shared value contains the root location and semantic display metadata; protocol-specific authority and root resolution remain owned by the backend. A root location uses the backend ID and a root item identity. A file backend maps this to its empty service-relative path; application/music catalog roots have no physical path. Do not add another root UUID when backend identity already identifies this namespace.

| Backend/root | Logical root | Authority |
| --- | --- | --- |
| `LocalFileBackend` for the existing full-filesystem product | `/` | Existing runtime-selected local/daemon access, including its current guard |
| `SandboxedLocalFileBackend` | App Documents, fixed local default | In-process access under the OS sandbox; no daemon lookup or fallback |
| SMB backend | Configured share root | Authenticated SMB session |
| FTP backend | Configured starting directory | Authenticated FTP session and its server permissions |

`SandboxedLocalFileBackend: LocalFileBackend` is a thin specialization. It supplies container-root configuration, in-process access and its initial places/default favorites through construction or narrowly scoped overridable configuration hooks. Shared preference mutation, sidebar streaming, listing adaptation and staging stay in the base class. Do not override copy/delete/rename implementations or create a second syscall layer.

The base class receives `DefaultStorage` and local access through DI. Configuration hooks must not run from a base initializer against partially initialized subclass state. Resolve immutable root/access inputs first, then initialize shared behavior. Subsequent root changes create a replacement backend with the appropriate identity and retire its old I/O/subscriptions.

Root configuration describes two different things explicitly: where navigation starts and what access is authorized. The shared root value alone grants no access. Breadcrumbs stop at the root, root-relative parent traversal cannot escape it, and actual operations enforce the relevant local sandbox boundary. Listing, details, source opens, mutation destinations, thumbnails and import/export must use the same resolved authority. A UI-only prefix check or a subclass overriding only a root title is insufficient.

The sandboxed specialization cannot be initialized with a privileged daemon access object. Its public construction path supplies in-process access and its allowed root, so a later reconnect cannot silently promote it. Privileged feature code cannot obtain raw daemon access through this backend. Keep the actual filesystem implementation shared in FilaFileOps, including canonicalization, symlink/hard-link handling and atomic publication; validate containment at the authority-owning boundary with race-aware filesystem operations where necessary.

This does not set `FileOperations.writableRoot` on the normal root-file-manager daemon or redefine its writable scope. That property's current File Provider role remains intact. Container-root adaptation is distinct from the daemon's bootstrap install root, which continues to come exclusively from `InstallRoot`.

Persist local sandbox bookmarks as stable root identity plus relative components. Resolve the Documents path at runtime: container installation UUIDs are not stable saved locations. For the existing root backend retain the legacy absolute-path representation at the storage adapter boundary. Never prefix an old `/var/mobile` favorite with Documents and present it as successfully migrated.

Additional user-created local roots are out of scope: no Add Local Folder backend flow, no persistent external-folder root registry and no app-group root backend feature. Sandbox starts at Documents; the full local backend keeps its appropriate existing root and presets. FTP starting directories and SMB shares are user-configurable remote scopes. Existing document-picker import/export and app-group/File Provider workflows retain their own authorization lifetimes and are not removed or promoted into new backend roots.

Sidebar locations derive from root capabilities. A container backend offers Documents and its permitted folders; bootstrap, whole-device mounts, root trash and privileged application actions are not offered. SMB/FTP roots have their own saved locations without borrowing local presets. Shared UI asks the backend for its contribution rather than checking class names or packaging flavors.

## App Store composition boundary

The sandboxed subclass establishes a reusable filesystem architecture for a potential App Store app; it does not by itself make the current Fila bundle eligible. Apple's review guidelines require public APIs (2.5.1) and constrain container access and downloaded/installed/executed code (2.5.2). Document-provider integration also has its own requirements (2.5.15). Source: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

A future Store composition must have a reviewed bundle/dependency graph and provisioning: omit the privileged daemon/private API integration and unsupported executable/IPA-installation features, and use public sandbox/document-provider access. Hiding menu items or removing private entitlements from the existing IPA is not proof that private symbols, frameworks and behavior are absent. Extract the in-process local access implementation into a public-API-only module if the current FilaClient/XPC graph prevents clean composition; do not inherit the whole jailbreak dependency graph merely to reuse a class.

The latest scope explicitly requires ApplicationBackend and MusicLibraryBackend to be absent from the sandboxed IPA binary. The two-composition plan above therefore supersedes the earlier same-app-binary assumption for that IPA. Full builds retain runtime daemon/local selection; the sandboxed composition injects only public sandbox access. This remains a design change, not an implemented target. Actual Store submission still needs its own binary/API/entitlement audit and review outcome.

## Shared interface

This is an interface sketch for review, not compiling source. The value contracts below are part of the proposal.

```swift
public protocol FileService: AnyObject, Sendable {
    func list(_ directory: ServicePath) async throws -> FileListing
    func details(_ path: ServicePath) async throws -> FileEntry
    func copyContents(of path: ServicePath, to descriptor: Int32,
                      progress: @escaping @Sendable (TransferProgress) -> Void) async throws
    func changes(in directory: ServicePath) async throws -> AsyncThrowingStream<Void, Error>
}
```

Each instance is bound to a local root, SMB share or FTP starting directory. Resolve the instance once; common consumers do not switch on FTP/SMB for each request.

| Value | Contract |
| --- | --- |
| `ServicePath` | Validated components relative to the instance root. Lexical composition is shared; actual resolution and wire encoding belong to the backend. |
| `FileLocation` | Stable service/profile ID plus `ServicePath`, for tabs, bookmarks and transfer sources. Identical paths on different hosts remain distinct. |
| `FileEntry` | Name, kind and available size/date/hidden metadata. Unknown remote metadata stays optional; no fabricated inode, UID, mode or epoch date. |
| `TransferProgress` | Completed bytes and optional expected bytes; unknown length is never a fake percentage. |

Root display names come from the service/profile, not a fictitious entry name. Preserve unknown and symbolic-link/reparse distinctions where available; navigation does not imply it is safe to treat a link as a real directory during mutation.

`list` returns FileListing, a concrete pull-based AsyncSequence of FileEntry batches. Adapter-owned iteration hides local cursors and protocol-specific paging. Request the next batch only when consumed; close resources on completion/cancellation. Preserve existing consumer entry limits and add metadata-byte/response budgets, enforced while receiving rather than after allocation. If an upstream SMB/FTP API collects the entire directory, use bounded lower-level requests or a focused upstream change; do not describe an array wrapper as streaming. Reaching a consumer limit reports incomplete results explicitly and never authorizes destructive cleanup from that partial listing.

The final common contract preserves local incremental first-load display. A refresh retains current rows until a complete replacement is ready, then applies the final diff. Catalog adapters may supply a bounded single batch; file adapters preserve pull-based enumeration. Keep one reload/subscription owner rather than a permanent parallel legacy loading loop.

`copyContents` borrows a writable descriptor for a new, empty private staging file. The caller owns it exclusively and keeps it open until return. The adapter writes bounded chunks, handles short writes/errors, does not close the descriptor and does not publish the destination. On return or throw, including cancellation, all adapter access has stopped. The owner discards incomplete staging.

The local implementation opens its source through `DaemonLink` and owns/closes that source descriptor. Network implementations own remote handles. No remote handle is passed off as a POSIX file descriptor; no file bytes enter daemon messages.

## Directory subscriptions

Every `changes(in:)` call creates an independent subscriber. Two tabs must both receive invalidations; sharing one `AsyncStream` iterator is not broadcast.

The payload is `Void`: the subscription already names the directory, and consumers only re-query. Exact insert/update/delete deltas would require ordering, loss recovery and snapshot versions that FTP cannot supply. `list` remains authoritative; events do not become a second directory database.

Required behavior:

1. Install observation before returning, then yield an initial invalidation. The first event triggers the initial listing, avoiding a list-then-subscribe gap.
2. Buffer one invalidation per subscription (`bufferingNewest(1)`). Bursts coalesce. This policy applies only to invalidation hints, never to job completion or search content.
3. Remain subscribed during a listing. An invalidation arriving mid-request stays pending and triggers another listing after the current one completes.
4. Bind the consuming task to a service instance and directory. Cancel on navigation and verify task/location ownership before publishing rows; cancellation alone cannot stop stale callbacks.
5. Cancellation removes the subscriber. The last subscriber releases timers/watch resources. Explicit disconnect/removal finishes streams and releases their resources; deinit is not the sole cleanup path.
6. Connection loss terminates affected streams with an error. Retain current rows. Retry creates a fresh connection/subscription and initial listing, with no promise of replay or exactly-once delivery.

The common browser consumes sequentially: await invalidation, consume the listing batches, publish under the initial-load/complete-refresh rules if still current, repeat. A buffered invalidation starts a follow-up reload. Manual refresh uses the same serialized reload owner instead of starting a competing fetch. On listing failure, end that observation attempt and offer retry while retaining rows; timer ticks must not generate repeated alerts.

| Backend | Initial sources | Later replacement |
| --- | --- | --- |
| Local | Known operation completion and bounded polling for observed directories | Native observation, in filad when privilege is required |
| SMBClient | Known mutation completion and bounded polling | CHANGE_NOTIFY if implemented in the selected library |
| FTP/libcurl | Known mutation completion and bounded polling | No standard server directory-push mechanism assumed |

One private observation owner per service keeps subscriber continuations and one timer per observed path. Start with the first subscriber, stop with the last; an initial interval of five seconds is a policy choice, not a latency guarantee. Every tick can invalidate without storing a second directory snapshot. The browser already owns rows and applies its normal diff.

Pause UI subscriptions in the background; resubscription forces a fresh listing. Serialize refresh requests with transfers, so timers cannot build an unbounded queue. Events remain invalidation hints whether triggered by a native watch or a polling timer; do not label polling as server-originated mutation.

`OperationCenter` remains the only owner of task receipts/progress. During local migration, its existing completion path feeds affected locations to the service's private invalidation owner; do not add another consumer of daemon job events. Failed/cancelled work can have partial effects and also invalidates. Future remote mutations invalidate from their adapter after settling, including uncertain publication results. Once migrated, a browser subscribes here instead of also reloading from `.filaJobFinished`.

Later native XPC watching adds narrow subscribe/unsubscribe messages and per-peer watch budgets. filad resolves/authorizes each directory, owns its watch descriptor, and sends only invalidation metadata. Disconnect releases watches; reconnect requires new subscriptions and re-query. This future extension carries no file contents, network credentials or generic execution operation.

## SMB implementation choice

Use the selected [SMBClient](https://github.com/kishikawakatsumi/SMBClient) under [MIT](https://github.com/kishikawakatsumi/SMBClient/blob/main/LICENSE), pinned to a reviewed release/revision. No fallback to an LGPL implementation is implied.

Inspected `Session.negotiate` defaults to SMB 2.0.2/2.1. Advertise SMB2; do not promise SMB3 encryption. A server supporting SMB3 may also accept SMB2, which must be verified for supported configurations. Source: [Session.swift](https://github.com/kishikawakatsumi/SMBClient/blob/main/Sources/SMBClient/Session.swift).

Connection setup owns host, port, share, optional domain and account credentials. Share enumeration is SMB-specific setup, not a shared filesystem method. Permit entering a known share when enumeration is unavailable. Initial authentication is account/password and explicitly supported guest access, not Kerberos SSO.

Map metadata once in the adapter. Use bounded `FileReader.read(offset:length:)` and checked local descriptor writes, not whole-file Data downloads. Explicitly close remote handles on failure/cancellation. Sources: [SMBClient API](https://github.com/kishikawakatsumi/SMBClient/blob/main/Sources/SMBClient/SMBClient.swift), [FileReader](https://github.com/kishikawakatsumi/SMBClient/blob/main/Sources/SMBClient/FileReader.swift).

The README lists CHANGE_NOTIFY and CANCEL as unimplemented. Therefore observation initially polls. Cancellation may require retiring/disconnecting a session to unblock pending I/O; prove all pending accesses finish before resources are reused. Test signing-required servers rather than inferring interoperability from an argument name. Source: [upstream feature list](https://github.com/kishikawakatsumi/SMBClient#supported-protocol-version).

Serialize each connection's complete operations, including suspended portions. Actor isolation alone does not prevent interleaving across `await`. Initially one operation runs per connection and polling waits behind transfers. If cancellation retires a shared connection, terminate other affected work honestly. Do not introduce a connection pool before the need is measured.

## FTP implementation choice

Use [libcurl](https://curl.se/libcurl/) under its permissive [curl license](https://curl.se/docs/copyright.html). Bundle a reproducible library build for iOS and the host harness; no subprocess or jailbreak package dependency. A small C bridge may hide variadic options/callback ownership without becoming a second generic curl API.

Configuration owns host, port, starting directory and transport security. Credentials arrive separately at connection time. Remote authentication/connection failures are actionable; do not apply the local daemon's indefinite Connecting behavior to them.

Use passive mode, EPSV with supported fallback, binary transfers and MLSD/MLST metadata. Accept legacy LIST formats only with fixtures; reject undecodable names rather than publishing corrupted ones. Enforce listing budgets while parsing. Sources: [RFC 3659](https://www.rfc-editor.org/rfc/rfc3659.html), [custom requests](https://curl.se/libcurl/c/CURLOPT_CUSTOMREQUEST.html).

Callbacks transfer bounded chunks and report bytes/cancellation. Keep the handle alive until all callbacks stop. Sources: [write callback](https://curl.se/libcurl/c/CURLOPT_WRITEFUNCTION.html), [progress and cancellation](https://curl.se/libcurl/c/CURLOPT_XFERINFOFUNCTION.html).

Plain FTP is explicitly unencrypted. Explicit FTPS validates certificate/hostname and protects both control and data channels, with no silent fallback to plaintext. Implicit FTPS is deferred until required by a supported server. Source: [RFC 4217](https://www.rfc-editor.org/rfc/rfc4217.html).

curl removed Secure Transport in 8.15.0. The FTPS TLS backend, trust integration, notices and binary size still need build evidence before FTPS is declared supported. Choosing libcurl does not settle these details. Source: [curl 8.15.0](https://curl.se/ch/8.15.0.html).

## Profiles, paths and failures

Saved profiles contain public settings and a Keychain credential reference. Passwords never enter URLs, logs, history or UserDefaults. A connected service owns its handle; do not mirror `isConnected` beside another authoritative resource state.

A service-relative root is a namespace, not a confinement guarantee. Local paths still pass through existing canonicalization/guards. Remote paths never pass through realpath on the phone. Reject NUL at the boundary and FTP control-channel CR/LF arguments. Backend-specific encoding must preserve supported filenames; universal lowercasing or Unicode normalization is incorrect.

Connection-setting changes retire the previous I/O instance/subscriptions before using a replacement. Display-name/credential updates retain preference identity; changes to the filesystem namespace follow the explicit new-identity rule above. Late responses cannot overwrite replacement rows.

Failures differ only when recovery differs: correct credentials, decide server trust, choose a destination, retry an unavailable connection, or show an operation failure. Cancellation is silent. Preserve vendor diagnostics without exporting a shared enum for every status code. A mutation with a lost final reply has an uncertain result and must not be retried automatically.

SFTP remains deferred. Its eventual implementation uses the same file-service contract; key/password choices and host-key trust belong to connection establishment. Do not add empty key/passphrase fields to current FTP/SMB configuration.

## App integration and writes

New remote navigation stores service-aware locations. Preserve current local Codable keys; absent service identity continues meaning local. Share listing presentation/sorting/subscription behavior where contracts match, while local-only actions retain their specialized backend. Do not scatter protocol switches across menus or force remote implementations to supply chmod, mount, trash and root APIs.

Migrate local queries/subscriptions onto the shared contract first, preserving incremental listings, then use the same machinery for remote browsing. Remove the old local reload notification path from each migrated screen; do not leave two competing refresh owners.

Preview downloads use FileSession's private workspace and remain owned until the viewer releases them. They are read-only snapshots. Editor Save must not imply remote save-back. Download-to-local publishes through the current guarded adjacent-temp/exclusive-rename flow. Extract `OperationCenter+Download.place` only when its second consumer arrives, keeping publication policy in one place.

Introduce WritableFileService with the destination-write and source-cleanup contracts required by the planned cross-backend copy/move implementation. Do not predeclare a universal perform(Operation) bag or an unused capability matrix.

Remote upload completion and publication are distinct: finish/close a temporary, then publish with verified server semantics. FTP check-then-rename cannot promise exclusive publication, even for a supposedly unused filename. Refuse unsupported no-replace/replace contracts or require a different workflow; never delete the original to emulate atomic replacement. Expose replacement only where the backend can uphold the selected policy; remote editor save-back remains separate from cross-backend copy/move.

A lost publication reply is not proof of failure. Retain recoverable content where practical and invalidate the parent without guessing the outcome. Remote deletion is explicitly permanent unless a real trash feature is integrated. Local xattr trash, metadata guarantees and copyfile/removefile behavior do not automatically apply remotely.

Cross-backend copy/move, including directory handling, follows the transfer contract below. Recursive permanent deletion unrelated to moving copied entries remains a separate destructive operation. App network tasks belong to OperationCenter; they do not inherit filad's lifecycle or promise continuation after app termination.

## Cross-backend copy and move

Cross-backend operations cover file/folder copy and move plus the basic operations needed to complete them, such as creating destination directories and resolving filename conflicts. Retain normal Copy/Cut/Paste and destination selection. Do not make the user manually download a file and then upload it to complete a move.

| Route | Execution |
| --- | --- |
| Local to local | Existing guarded native jobs, copyfile/clonefile/removefile and same-volume rename where applicable |
| Same remote backend | Backend-native rename for supported moves; use transfer when copying requires it |
| Local to remote | Read source through local access, upload and publish through destination backend |
| Remote to local | Download to private staging, then publish through the guarded local destination flow |
| Remote to remote | Read from source into private staging, then upload/publish through destination |

Add one concrete `FileTransfer` executor, called by `OperationCenter`, rather than another job manager. It coordinates source/destination FileLocations and delegates protocol I/O to FileService plus its writing capability. OperationCenter owns the task, progress, cancellation and final receipt. FileTransfer owns temporary resources and per-operation completion evidence only; it does not persist a second history or duplicate task state.

Use a `WritableFileService` capability for the destination writes/rename/removal actually required by these operations. It must express destination conflict/publication semantics, not a generic command string. The selected source/destination capabilities determine offered actions; controllers do not branch on SMB/FTP names. Readable sources can be copied; a move additionally requires source cleanup support. Applications and music items do not implement this capability by pretending they are files.

Start with bounded, per-file private staging for routes requiring a relay. Process directory contents incrementally instead of staging an entire tree. A large file can require local free space equal to its staging size; check/reserve storage with existing mechanisms and report a real capacity failure. Future streaming between remote peers is an optimization, not another user operation. All reads/writes are chunked and no content enters filad messages.

Copy succeeds only after the destination adapter confirms complete content transfer, successful close/finalization and publication under the selected conflict policy. A temporary object is not the destination. Use available length/identity/checksum evidence without presenting a successful protocol response as an end-to-end cryptographic verification or crash-durability guarantee. If publication's final reply is lost, report an uncertain result and refresh the destination; do not blindly retry or delete the source.

Move uses the same copy path followed by guarded source cleanup. Keep the source until its destination copy is complete and published. Before removing source entries, revalidate them against the source identity/version evidence captured by the transfer. If changed, unverifiable or ambiguous, retain them and report that copying finished but the source was not removed. FTP metadata checks cannot provide an atomic compare-and-delete guarantee; document/test that protocol limitation rather than claiming filesystem-level atomicity. Never use a later ENOENT as proof this operation moved the source.

For directories, preserve hierarchy and empty directories. Capture the entries actually copied; remove only those verified entries after the chosen source root has been completely copied, then remove directories only if empty. Do not recursively delete a freshly re-listed source tree: it may contain files added after copying. A changed/nonempty source directory remains with an honest partial-move result. Remote traversal must be bounded, cancellable and avoid following symbolic links/reparse points implicitly. Unsupported link/metadata preservation must be resolved explicitly rather than silently dereferenced or silently dropped. Native local tree operations remain delegated to the existing bulk APIs.

Default destination policy does not overwrite. When a name is occupied, use the existing conflict interaction with Keep Both/Skip/Replace only where the backend can honor the chosen semantics. FTP upload/rename cannot silently be treated as exclusive or atomic replacement; either use a proved publication mechanism or report the unsupported requested policy. Copy/move support is not permission to delete an occupied destination before uploading. Cross-backend metadata is limited to what the destination represents; do not advertise APFS clone/xattr/ACL equivalence for FTP.

If source deletion fails after publication, keep the destination, retain remaining source entries and report “copied; source could not be removed.” Do not delete the good destination to roll back, and do not label the overall move successful. A skipped source item likewise remains. Cancellation stops additional work and cleans only owned unpublished temporaries where possible; published destinations remain. A cancel racing publication/cleanup is reported using the actual settled result, never assumed to have undone prior work.

FileClipboard must hold backend-aware locations in the snapshot that started a paste. Copy remains reusable. Consume a cut selection only after the whole corresponding move succeeds; on a failed/partial batch preserve that selection rather than guessing which roots disappeared. A later clipboard selection is unaffected by an older completion. Repeating a partial move must use explicit conflict handling, not silently overwrite an already-published copy.

Progress is one operation with honest transfer phases and byte totals, including both relay legs when known; do not reach 100 percent at download completion while upload is pending. Backend progress can update detail text without creating separate Upload/Download receipts for one user move. Invalidate affected source/destination listings after settled work, including failed or cancelled partial operations. Shell and sidebar metadata follow their own relevant updates.

Application install/export and music import/export remain domain actions owned by ApplicationBackend/MusicLibraryBackend. Their handlers can reuse FileTransfer for an actual file leg, but Cut/Paste must not implicitly uninstall an application or delete a library track. Existing music export restrictions continue applying before a transferable file is produced.

Add real-adapter tests for local-to-SMB, FTP-to-local and FTP-to-SMB routes; directory/empty-file cases; full storage; conflicts; a changed source; cancellation before/after publication; lost publication acknowledgment; failed source removal; and stale clipboard completion. Check final source/destination contents, not just the client error. This is design work only; all implementations remain subject to the file-operation clarity/review gate.

## Implementation and review sequence

1. Extract `FilaBackendKit` and public in-process `FilaLocal`, rename/decouple the old local-operation protocol as `LocalFileAccess`, and introduce logical backends with injected scoped preference storage. Move local bookmark/history ownership while preserving persisted data; implement sidebar streams and independent directory subscriptions.
2. Pin SMBClient and prove iOS 15/host builds, bounded listing/transfer, login/manual share, signing compatibility, timeout and cancellation.
3. Build libcurl; implement FTP metadata/transfer and prove FTPS with the selected TLS backend.
4. Extract ApplicationBackend/FilaApplications and MusicLibraryBackend/FilaMusicLibrary with their concrete typed actions; move their preference and refresh ownership out of controllers.
5. Extract BackendListViewController and migrate the three list subclasses. Integrate profiles, sidebar aggregation, remote browsing and download through OperationCenter. Preserve streamed initial file listings and remove old global preference/notification paths from migrated consumers.
6. Introduce FilaSandboxed composition and prove app/music feature code is absent from the ordinary IPA while remaining functional in full builds. Verify all wrappers and shared-container contracts.
7. Implement cross-backend copy/move and necessary destination writes through FileTransfer/OperationCenter. Prove publication, conflicts, cancellation, source changes and partial-success behavior before enabling each supported operation; complete file-operation reviews.

Tests must prove observable contracts: two subscribers both update; cancelling one leaves the other live; an update during listing schedules a follow-up; stale responses cannot publish after navigation/reconfiguration; bursts remain bounded; backgrounding releases polling; retry gets a fresh listing; transfer cancellation stops descriptor use before cleanup; multi-GB files and oversized directories respect memory limits; failed partial work invalidates without claiming success.

Preference/sidebar tests additionally prove modules cannot be toggled or hot-unloaded, failed bootstrap emits no sidebar placeholder, application/music favorites are absent, cross-section reordering is rejected, backend sorting/layout settings do not alter another backend, and legacy local values survive, explicitly empty favorites remain empty, two remote scopes do not collide, favorite changes publish without a network connection, a slow/failing backend does not block other contributions, profile removal rejects late snapshots, global history disabling clears offline scopes, and merged recents retain deterministic order without fabricated legacy dates.

Root tests prove container-relative favorites survive a changed installation path; navigation and every I/O entry point honor the same root authority; sandboxed construction never reaches the daemon; built-in local roots expose no additional-root creation flow; and normal root-backend access is not accidentally fenced into the app container or bootstrap. Run the same shared preference/sidebar contract tests against the full local class and its sandboxed subclass.

Real-server targets: Samba, Windows with signing required, a representative NAS, and FTP/FTPS fixtures covering modern/legacy listings and certificate errors. These are planned proofs, not compatibility claims. Implementation still requires harness/check/build, iOS-floor audits and the file-operation review gate.

Apply code-clarity: directory contents have one authority, subscriptions have one owner, operation receipts have one owner, and every retained type/field/error changes a real consumer's behavior. This documentation-only revision implements none of the proposed operations.
