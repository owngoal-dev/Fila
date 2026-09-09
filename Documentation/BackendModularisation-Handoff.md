# Backend modularisation — handoff (branch `fila-backends`)

Status as of 2026-09-09. Plan: `PLAN.md` (phases 0–8). This file records
what is done and exactly where to resume. It is a
working note and is deleted in Phase 8.

## Done and committed

| Phase | Commit | Summary |
| --- | --- | --- |
| 0 | `e392f6a` | Baseline and inventory (docs only). |
| 1 | `0d60bba` | `FilaBackendKit` contract, `FilaBackendModule.plist` manifest, `<Name>Module` entry classes, `BackendModuleDiscovery`/`BackendRegistry`, `FilaCore.framework` (the one image every FilaKit product lives in, re-exported), `FilaLocal.framework`, `BackendComposition.bootstrap()` in `main`. |
| 2 | `9a8d954` | `FilaClient` reduced to the neutral local contract (`LocalFileAccess`, `LocalFileService`, `LocalFileBackend`, `SandboxedLocalFileBackend`); `DaemonLink`/`DaemonFileService` moved to the `FilaPrivileged` package target (no product; `FilaPrivileged.framework` compiles the directory). Grace rule unchanged. |
| 3 | `efde86f` | `DefaultStorage`/`UserDefaultsStorage`, backend-owned favourites/history/listing options with legacy keys, `SidebarModel` merging per-backend snapshots, per-directory invalidation subscriptions; `AppPreferences` trimmed to app policy. |

Verified per phase: `make harness` (420 tests at Phase 3), `make check`,
simulator Debug build, static product inspection (`otool -L`, `nm`). Nothing
was run on a device: daemon XPC, entitlements and real filesystem mutation as
root are **untested** on this branch.

## Phase 4 — done

| Phase | Commit | Summary |
| --- | --- | --- |
| 4 | see `git log` | `FilaBackendUI` (`BackendListViewController<Item>`, `StatusView`, `FilaUI`, `BackendRowCell`, `BackendScreens`), `FilaApplications` and `FilaMusicLibrary` as package targets plus `Frameworks/<Name>` module frameworks with their own catalogues, `FileBrowserViewController` on the shared list base, the shell routed by `BackendLocation` and the applications capability. |

What Phase 4 settled, beyond the handoff's earlier list:

- `FileBrowserViewController` (was `BrowserViewController`) subclasses
  `BackendListViewController<FileNode>`. The base owns the listing loop,
  the change subscription and the held reload; the browser supplies the
  layout, cells, decorations, footer, selection and file actions. Its
  page stream is the reader's pull-based iterator wrapped with
  `AsyncThrowingStream(unfolding:)`, so the next backend request still
  starts only when the list asks. Cell registrations are built in `init`:
  UIKit refuses one created inside the cell provider, and a lazy
  registration is created exactly there.
- `BackendListViewController` starts with `isLoading == true`, so no list
  calls itself empty before its first listing; it has `refreshRequested()`
  for the pull-to-refresh control and `redraw()` for the reload-data path a
  layout or unit change needs.
- `StatusView` clamps its centring band to the list's own edges: a list
  that stops short of the screen bottom, or begins below the safe area,
  centres the panel in what it shows rather than in a band that runs on
  past its edges. Search's keyboard-following behaviour is unchanged.
- `DirectoryObservation` has one way into polling: a baseline `stat`, then
  one hint to the directory's subscribers, then the ticks. The first
  subscriber, an operation's `invalidate` and resuming from a pause all
  restart the watch through it, so the listing a hint starts is never older
  than the baseline the next tick compares it against, and a `stat` that
  outlives its cancelled watch installs nothing. That replaced an epoch
  guard that closed the same race on one path only. The cost is one `stat`
  round trip before each hinted listing. Previously flaky tests pass.

Verified: `make harness` (430 tests), `make check`, simulator Debug build
with zero warnings, the app browsing the Mac's filesystem in the simulator
(root listing with footer, loading panel, search, Applications), static
product checks (`otool -L` lists both module frameworks non-weak;
`NativeMusicLibrary` only in `FilaMusicLibrary.framework`;
`LSApplicationWorkspace` only in `FilaApplications.framework`), and
`make build` for the extractor diff. Reviewed with `/code-review`;
`/code-clarity` is not installed on this machine.

Still nothing on a device: daemon XPC, entitlements and root mutation are
untested on this branch.

## Resume here: Phase 5

Phases 5–8 per `PLAN.md`. `Packages/FilaKit/Binaries/libcurl.xcframework`
(libcurl 8.14.1, untracked) is prepared for Phase 6. Build with an isolated
DerivedData (`DERIVED_DATA=/private/tmp/fila-dd-<name>`).

## Decisions worth keeping

- One `FilaCore.framework` links every shared SwiftPM product exactly once
  and `@_exported import`s them; a product linked by two images duplicates
  Swift metadata. Code that must stay out of the sandboxed IPA but be host-
  testable is a package **target without a product** compiled directly by its
  framework. Pure-C/ObjC targets with no dependency closure may be products.
- A catalogue backend contributes its root row only while it has something
  to show; the sidebar, tab switcher and links open it through
  `registry.screen(for:)`, never a concrete type.
- The tab store records a directory per tab; a catalogue tab restores to the
  last directory. (Before, Music restored to `iTunes_Control`.)
