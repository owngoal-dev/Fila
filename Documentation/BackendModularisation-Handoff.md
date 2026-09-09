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

## Phase 5 — done

| Phase | Commit | Summary |
| --- | --- | --- |
| 5 | see `git log` | `FilaSandboxed` app target and scheme over the same `Fila/` sources, linking and embedding `FilaCore` and `FilaLocal` only; `make build-sandboxed` / `make compile-sandboxed` into `$(DERIVED_DATA)-sandboxed`; `make ipa` packages it and `make packages` builds both compositions at one build number; `Scripts/verify-composition.sh` in every archive verification; composition-aware build receipts and extractor diff. |

What Phase 5 settled:

- The two compositions differ in the link line only. `FilaSandboxed` has
  `-needed_framework FilaLocal` alone, no dependency on `Filad`,
  `FilaArchive` or the three excluded frameworks, and no
  `NSAppleMusicUsageDescription`. Its product is also `Fila.app`, so it
  builds into a sibling DerivedData; `XCODEBUILD_DERIVED_DATA` is a
  target-specific make variable for that recipe.
- `build-package-inputs.py --products Fila.app` records which composition
  a products directory holds; `package-ipa.sh` asks for the sandboxed
  receipt and refuses the full build's directory.
- `verify-composition.sh full|sandboxed` checks the embedded frameworks,
  the executable's required load commands, a version match on every
  first-party framework, and — for the sandbox — the absence of the
  excluded modules' class names, private-framework paths and selector
  strings from every Mach-O in the bundle. It runs from `verify-ipa.sh`
  (tipa → full, ipa → sandboxed) and `verify-deb.sh` (full).
- Shell residue removed: a `fila://` link into Applications in a copy
  without the module says so instead of pointing at a switch that does
  not exist; the Appearance settings list only the presets this launch can
  show (`LocalFileBackend.offersPreset`, and the two catalogue presets only
  with their module registered).
- The simulator is pinned to the container: `LocalFileService.processReach`
  is `.container` under `targetEnvironment(simulator)`, and
  `FilaLocalModule` builds `SandboxedLocalFileBackend` whenever the reach is
  the container, before it looks for a privileged provider. So both
  compositions browse the simulated app's Documents directory there, as the
  `.ipa` does on a device; the full filesystem root is a device-only test.
- Under container reach a tab's ancestor chain starts at the local
  backend's `rootPath` (Documents), not at the process Home, and the path
  bar's first crumb is that root under its own name rather than the device
  followed by every component: the simulator showed the container UUID
  directory as a crumb above Documents, with Back leading there.

- Only the full build bumps the build number. The sandboxed build takes
  the number as it stands, so `make compile` then `make compile-sandboxed`
  leaves the full build's receipt valid (`Configuration/` is a receipt
  input) and both wrappers at one number. The sandboxed recipe refuses a
  DerivedData equal to the full one: both compositions are `Fila.app`, and
  a copy-files phase never removes the frameworks an earlier build left.
- Under container reach the tab store reopens any remembered directory
  the container does not hold at the root, not just `/` and `/var/mobile`:
  a sideloading tool's reinstall retires the container UUID, and the
  previous build started tabs at Home rather than Documents.
- Reordering presets in Appearance merges the shown order back into the
  full saved order, so a preset this launch does not offer keeps its place
  for the launch that has it.
- A privileged module registered beside a sandboxed process is logged as
  bypassed. The bypass itself is deliberate — the daemon is out of a
  sandbox's reach — but a copy demoted to Documents should say so.
- `package-ipa.sh` expands the empty receipt-option array with
  `${receipt[@]+"${receipt[@]}"}`: `/bin/bash` is 3.2, where an empty
  array under `set -u` is fatal, and the `.tipa` is that case.
  `verify-composition.sh` finds the first offending file with `-quit`
  rather than `| head -1`, which SIGPIPEs under `pipefail` and loses the
  message.

Reviewed with `/code-review`: its finder pass ran to completion and its
verification pass was cut off by a rate limit, so the candidates above
were verified by hand. Candidates left as they are: the composition
roster is written in four places (the two `-needed_framework` lists, the
verifier's `shared`/`excluded` arrays, the extractor's `COMPOSITIONS`
table) and could be owned by the module manifests; the preset-to-catalogue
mapping is written in `SidebarLocation` and `offeredPresets()`; the
sandboxed DerivedData compiles every shared target a second time, the cost
of two targets that both produce `Fila.app`. The simulator pin is a
platform condition in the file layer by the user's decision, and
`AGENTS.md` names it as the one such condition. `/code-clarity` is not
installed on this machine.

Verified: `make check`, `make harness`, both Release device builds without
a build-number bump (`CI=1`), the extractor diff for both, `make tipa` and
`make ipa` with their verifications, `Tests/test-packaging.py` against
both product directories, `Scripts/Tests`, and the sandboxed simulator
Debug build launched and browsing. Nothing on a device.

## Resume here: Phase 6

Phases 6–8 per `PLAN.md`. `Packages/FilaKit/Binaries/libcurl.xcframework`
(libcurl 8.14.1, untracked) is prepared for Phase 6. Build with an isolated
DerivedData (`DERIVED_DATA=/private/tmp/fila-dd-<name>`); the sandboxed
composition lands beside it in `<name>-sandboxed`. A new module framework
joins the sandbox by adding it to `FilaSandboxed`'s Frameworks, Embed
Frameworks and `-needed_framework` lists; the verifier's `shared` list in
`verify-composition.sh` names what both compositions must carry.

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
