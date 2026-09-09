# Backend migration inventory (Phase 0)

Recorded 2026-09-09 on branch `fila-backends` at the start of the
[PLAN.md](../PLAN.md) implementation. This is the owner inventory Phase 0
asks for: what owns which state today, where the private surface lives, and
the baseline every later phase is measured against. It describes the tree
*before* the migration; the phases that follow rewrite the code and then this
file is superseded by [Architecture.md](Architecture.md).

## Baseline

| Gate | Result |
| --- | --- |
| `make harness` | 378 tests in 57 suites passed, 10 skipped (device-only fixtures); music import compatibility tests passed |
| `make check` | passes (needed `ldid-procursus` and `dpkg` from Homebrew on this Mac) |
| Toolchain | Xcode 26.5 (17F42), Swift 6.3.2, macOS 26.4 |
| Working tree | clean at f504024; no unrelated local changes to keep separate |
| Test surfaces | macOS harness and iOS simulator only. No vphone or jailbroken device is available, so the privileged XPC path, entitlements and bootstrap layouts are **not** verifiable here and every later phase says so. |

## State owners today

| State | Owner | Persistence | Notes |
| --- | --- | --- | --- |
| Favorites, recents, last directory, sort, hidden files, layout, per-folder layout, sidebar preset order and hidden presets | `AppPreferences.shared` (`Fila/Application/State/AppPreferences.swift`) | `UserDefaults.standard`, bare keys: `favorites`, `recents`, `recentFiles` (legacy, read then removed), `lastDirectory`, `sortKey`, `sortAscending`, `showsHidden`, `layout`, `folderLayouts`, `presetOrder`, `hiddenPresets`, `recordsRecents`, `launchLocation` | Setter posts `.filaSidebarChanged` (favorites/recents) or `.filaPreferencesChanged` (presets). `defaultFavorites` reappear when the key is absent; there is no absent-versus-empty distinction. |
| Application list sort and scope | `AppPreferences.appSort` / `appScope` | keys `appSort`, `appScope` | Read only by `AppListViewController`. |
| App shell toggles (trash, guard override, run programs, script redirect, applications visible, text viewer, WebDAV server) | `AppPreferences` | `usesTrash`, `allowsGuardOverride`, `showsApplications`, `runsPrograms`, `redirectsScriptInterpreters`, `wrapsLines`, `highlightsSyntax`, `serverPort`, `serverUsername`, `serverPassword`, `serverRoot`, `serverBackground` | Stay shell-owned. |
| Tabs | `BrowserTabStore.shared` | `tabState` (JSON), `currentTab`, legacy `tabs` | Rewrites stacks through `BrowserTab.chain` for the `.local(.container)` backend at construction. |
| Clipboard | `FileClipboard.shared` | none | `beginPaste` snapshots a revision; `finishPaste` consumes a cut only when the revision matches, it was a cut and the batch succeeded. |
| Operation receipts and in-flight breadcrumbs | `OperationCenter` (owned by `FileSession.operations`) | `wiki.qaq.fila.operations.inflight` | Only consumer of `DaemonLink.jobEvents`; `DaemonLink.searchResults` has no consumer. |
| Log level | `LogPreferences` in `LogViewController.swift` | `wiki.qaq.fila.log.level` | Deliberately outside `AppPreferences`. |

Backend identity leaks into state types in four places that read
`FileSession.shared.hello?.backend` directly: `AppPreferences.launchDirectory`,
`BrowserTab.chain`, `BrowserTabStore.init` and `SidebarLocation.jumpList`.
`SystemCapabilities.showsApplications` and `runsPrograms` are the chokepoints
that gate private-API paths on the same handshake.

## Directory refresh paths

`.filaJobFinished` (declared in `OperationCenter.swift`) is the only directory
invalidation channel and has three posters and four observers:

- Posters: `OperationCenter.finish` (sets `userInfo["kind"]`),
  `FileActions.rename` (bypasses `OperationCenter.rename` entirely) and
  `IntentSupport.announceChange`.
- Observers: `FileBrowserViewController.jobFinished`, `SidebarViewController`
  (trash probe), `SaveDestinationViewController.filesChanged`,
  `FileProviderDomain` (signals the provider).

`.filaSidebarChanged` is posted by both `AppPreferences.store` and
`OperationCenter.changed`, for unrelated reasons.

## Private surface and its future owner

| Symbol | Where | Owner after the split |
| --- | --- | --- |
| `xpc_connection_create_mach_service` (`@_silgen_name`), `CFilaXPC` shim, six `*+XPCCoding.swift` files | `FilaProtocol` | Shared wire vocabulary; stays in FilaProtocol, which both the daemon and FilaPrivileged link |
| `DaemonFileService` (`import XPC`), `DaemonLink.openTerminal` / `closeTerminal`, `DaemonInstallation` | `FilaClient` | FilaPrivileged |
| `LSApplicationWorkspace`, `LSApplicationProxy` KVC, `IconServices` (`ISIcon`) via `dlopen`, `InstallCoordination`, `MobileInstallation` | `Fila/Services/Applications`, `Fila/Services/Installation` | FilaApplications |
| `MusicLibrary.framework` private classes (`ML3*`) through `NativeMusicLibrary.m` and the app bridging header | `Fila/Services/Music` | FilaMusicLibrary |
| `proc_pidpath`, audit token and entitlement lookups, `posix_spawn` of the terminal holder and `fila-archive` | `Filad`, `FilaFileOps` | Daemon only |

Entitlements that belong to a module rather than the shell:
`wiki.qaq.fila.client` and the `wiki.qaq.fila.service` mach lookup
(FilaPrivileged); `com.apple.private.InstallCoordination.*` and the
`com.apple.iconservices*` lookups (FilaApplications). The IOKit user-client
classes belong to the terminal.

## Packaging facts the later phases rely on

- No first-party dynamic framework exists yet. Every FilaKit product is
  static; `Fila.app/Frameworks` holds only the binary xcframeworks and the
  Swift compatibility dylibs. There is no Embed Frameworks phase.
- `Scripts/sign-frameworks.sh` and `Scripts/verify-payload.py` enumerate
  `Frameworks/` by glob and will sign and check new bundles without edits.
  `verify-payload.py` requires every embedded framework to carry **empty**
  entitlements and the iOS floor.
- `Scripts/check-extracted-strings.py` names its targets in a table; a new
  target with user-facing strings is invisible until added there.
- `Scripts/check-ui-libraries.sh` roots its greps at `Fila/` and
  `FilaTerminal`, and allowlists `Applications/AppDetailViewController.swift`
  for `subtitleCell()`.
- `Scripts/build-package-inputs.py` digests a fixed list of source
  directories; new framework directories must be added or the receipt lies.
- Versions come only from `Configuration/Version.xcconfig` through the
  project-level xcconfigs, so any new target inherits them by default.

## Vendor libraries

- SMBClient 0.3.1 (`kishikawakatsumi/SMBClient`, MIT) builds on this
  toolchain unmodified; its manifest floor is iOS 13.
- The iOS SDK ships no libcurl headers. `Scripts/build-libcurl.sh` builds a
  pinned curl 8.14.1 (the last release with the Secure Transport backend, so
  FTPS validates against the system trust store) as an xcframework with only
  FTP and FTPS enabled.

## Review gate

Every change from Phase 2 onward that touches the file layer goes through
`/code-clarity` and `/code-review` before its phase is called done; a green
`make harness` is a precondition, not a substitute.
