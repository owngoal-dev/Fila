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

## Phase 6 — done (SMB only)

| Phase | Commit | Summary |
| --- | --- | --- |
| 6 | see `git log` | `FilaSMB` package target and `FilaSMB.framework` (in both compositions): `SMBBackend` per saved share, `SMBConnection`/`SMBFileService` over the vendored SMBClient, `SMBProfileStore` with passwords in the keychain, the `FilaSMBModule` entry with a connection setup, the setup screen, and `FileServiceBrowserViewController` in FilaBackendUI as the browser over the neutral file contract. Kit contract 2: `CredentialStore` on the host, runtime `addBackend`/`removeBackend`, `connectionSetup` registrations, `RemoteDirectoryObservation`. |

FTP and SFTP are **not implemented and not planned** (the user's decision
during this phase); `Scripts/build-libcurl.sh` stays as a record but nothing
uses it. Delete it in Phase 8 unless FTP is revived.

What Phase 6 settled:

- **SMBClient is vendored** at `Packages/SMBClient` (upstream revision
  `66eafaa6`, 2026-04-27, MIT) with one added method,
  `Session.queryDirectoryPage(fileId:pattern:restart:)`, because upstream's
  public listing collects a whole directory before returning and its request
  primitive is private; `FILA-VENDOR.md` records why, what changed and how
  to update. The revision on `main` was preferred over tag 0.3.1 for four
  transport fixes. The user asked whether a fork could replace the copy:
  yes, by pointing the package reference at a fork carrying that method;
  the swap is the package reference in `Package.swift` and the pbxproj.
- **One request at a time per session**, through `SMBConnection`'s turn
  gate; a directory handle stays open on the server between pages so a
  details call lands mid-listing. **A timeout or a cancellation retires the
  session**: the vendor has no cancel, so closing the TCP connection is the
  only way to bring a pending request back, and every handle on that
  session then fails as `disconnected` and its consumer starts over on a
  fresh one. Connect budget 20 s, request budget 30 s.
- Listing is one QUERY_DIRECTORY response per batch (≤ 1 MiB), `.` and
  `..` dropped, reparse points reported as links; `copyContents` reads 1 MiB
  chunks straight into the descriptor with a short-write loop. A component
  containing `\ : * ? " < > |` is refused before it reaches the wire.
- Polling is `RemoteDirectoryObservation` (FilaBackendKit): five-second
  stamp of the directory's write time, hints only on change, paused with the
  app, ended with an error when the session is lost.
- Identity: `smb:<profile UUID>`; a rename or credential change keeps it, a
  changed host, port or share is a new profile and a new backend (the setup
  screen mints the UUID). Removing a share removes its record, its
  preference key and its keychain item.
- The remote browser is `FileServiceBrowserViewController` on the shared
  list base, not `FileBrowserViewController`: the local browser is bound to
  `FileNode`, descriptors and jobs, and making it neutral is a phase of its
  own. This is a recorded deviation from PLAN.md's "one file controller";
  Phase 7's cross-backend clipboard is where the two must meet. A file opens
  as a snapshot (≤ 512 MiB) downloaded into the app workspace and shown by
  the app's own viewer through `BackendShell.preview`; *Save to Fila…*
  copies it through the operation centre. The download has no Cancel: the
  app's progress card has none, and Phase 7 moves transfers into
  `OperationCenter`, which has.
- The shell gained a **Servers** sidebar section (remote file roots plus one
  *Add …* row per registered setup, swipe to edit or remove), a keychain
  `CredentialStore`, and `SidebarModel` now follows registry additions and
  removals. `BackendShell` gained `makeWorkspace`, `fileIcon`,
  `progressCard`, `preview` and `open(location)`.
- Tabs still record local paths: a remote screen in a tab restores to the
  last local directory, like a catalogue screen.
- `FilaBackendUI` now owns a string catalogue (`bundle: .module`) and is in
  the extractor table; `check-localization.sh` walks `Frameworks/` too.

Reviewed with `/code-review` on Opus (the forked skill runs on the session's
model, so the review was run as an Opus agent by hand). `/code-clarity` is
not installed on this machine. The review's findings and what was done:

- The guest switch could not be turned off: `SMBProfile.isGuest` counted an
  empty user name as guest, so account mode snapped back. Now only a nil
  user name is guest, an empty one is `ValidationFailure.usernameMissing`,
  and the wire rule (`SMBConnection.Configuration.isGuest`) is unchanged.
- Every AlertController card in the setup screen resolved its
  `String.LocalizationValue` against the app bundle and would have shown
  English. The cards now take strings resolved with `bundle:` first, the
  way `MusicTrackViewController` does. No check can catch this class of
  bug: the keys extract and match, they only resolve against the wrong
  bundle at runtime.
- A cancelled transfer or listing skipped its CLOSE, since `perform`
  checks cancellation first. `SMBConnection.closeHandle` runs the close in
  a detached task so cleanup happens whatever the caller's state.
- The disconnect handler captured its own client strongly through the
  client's stored closure; every retired session leaked. Weak now.
- SMB polling was never paused on background: `setObservationPaused` is a
  `FileBackend` requirement and the app delegate walks every file backend.
- `FileServiceBrowserViewController.service` was dead and kept the screen
  alive through the listing task. Removed.
- A re-identified share was removed before the new one was written; the
  order is now write, register, then remove. `SMBProfileStore.save` puts
  the record back when the keychain refuses the password.
- `SMBFileService`'s handler-installed flag moved into the actor
  (`installLostHandler(token:)`), so the `@unchecked Sendable` class holds
  no mutable state.
- Left as is: a share name in the *Choose Share* card is looked up as a
  localization key by the package's `String` overload. Cosmetic, and the
  package offers no non-localizing path.

Verified: `make check`; `make harness` (458 tests, including 14 unit tests
for the SMB package and 5 for the observer); the live suite
`SMBLiveServerTests` (9 tests, opt-in through `FILA_SMB_SERVER`) against an
impacket SMB2 server on the Mac: 2,502-entry paged listing with Unicode
names, an abandoned listing, details of root/file/empty/missing, a 48 MiB
chunked copy with monotonic progress and an empty file, cancellation that
leaves the descriptor alone and reconnects, connect and request timeouts,
wrong password and unknown share, change hints that end on disconnect; both
Release device builds with `CI=1` and clean extractor diffs; all four
wrappers with composition verification; the simulator Debug build launched
on the iPad with a seeded guest profile showing the Servers section. Not
done: tapping through the setup and browser screens (synthetic clicks are
refused on this Mac), Windows signing-required, Samba and NAS servers,
multi-GB files, anything on a device.

## Resume here: Phase 7

Cross-backend copy and move per `PLAN.md`. Build with an isolated
DerivedData (`DERIVED_DATA=/private/tmp/fila-dd-<name>`); the sandboxed
composition lands beside it in `<name>-sandboxed`. A new module framework
joins the sandbox by adding it to `FilaSandboxed`'s Frameworks, Embed
Frameworks and `-needed_framework` lists; the verifier's `shared` list in
`verify-composition.sh` names what both compositions must carry. To run the
SMB live suite, start an SMB2 server (impacket's `smbserver.py -smb2support`
works unprivileged on a high port) and set `FILA_SMB_SERVER=host:port`,
`FILA_SMB_SHARE`, `FILA_SMB_USER`, `FILA_SMB_PASSWORD`, `FILA_SMB_FIXTURES`.

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
