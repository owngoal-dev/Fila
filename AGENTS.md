# Fila — Agent Notes

Root file manager for jailbroken iOS 15+ — roothide and rootless bootstraps
both. **iOS only**: there is no Mac Catalyst build and no macOS product.
(`Package.swift` still declares a `.macCatalyst` platform so the package
resolves; that is not a product and nothing builds one.) The
app runs as `mobile`; with the privileged backend, the bundled `filad`
LaunchDaemon opens files and performs filesystem mutations as root. Without
that backend, `LocalFileService` works under the app's own OS permissions.

The single idea the whole design hangs off: **`filad` opens files, it does not
read them.** It hands the descriptor back over XPC and forgets it. Bytes flow
between the app and the kernel with nothing in between.

## Hard rules

- **File operations are syscalls, never subprocesses.** No shell, no `cp`, no
  `unzip`, no `ps` — file operations use syscalls and libSystem in the shared
  `FilaFileOps` layer. Most of those tools don't exist on the device anyway.

  Execution itself is no longer forbidden: Fila runs binaries and hosts a
  terminal, the way Filza does. But the reasoning that used to forbid it is now
  the specification for it — **a root daemon that can be talked into running a
  command is a root shell for whoever can talk to it** — so `FilaOperation`
  must never grow a generic `exec(path, argv)` case, and the daemon's exposed
  surface stays narrower than "run what I tell you". Anything that spawns says
  plainly what it spawns, as whom, and what it refuses.
- **Spawn normally.** Fila uses ordinary `posix_spawn`, never `fork`, `forkpty`,
  `execv`/`execve` or `POSIX_SPAWN_SETEXEC`. The daemon's internal
  `--terminal-session` mode establishes the controlling terminal and drops
  credentials before spawning its fixed program; shell internals are the shell's
  responsibility. No generic argv/environment operation is added to XPC.
- **File bytes never enter the daemon.** `FilaOperation` has no `readFile` and
  no `writeFile`, and it never will: the client asks for a path, the daemon
  `open(2)`s it as root, and the descriptor travels over XPC
  (`xpc_dictionary_set_fd`). This is not an optimisation. launchd caps a daemon
  at 6 MB on the device (jetsam), a file manager routinely moves gigabytes, and
  the first large read through a message would kill the daemon mid-operation.
  It is also why `filad` needs no second process the way `ighostvtd` does.
- **Bulk work is `copyfile(3)`, `removefile(3)`, `clonefile(2)` — never a
  hand-written tree walk.** Their state callbacks give progress and
  cancellation, their memory is flat, and they preserve xattrs, ACLs, resource
  forks, BSD flags and sparseness. Every walk written by hand loses some of
  those silently, and the loss shows up as a user's data quietly changing.
  A same-volume copy tries `clonefile(2)` first: on APFS it is instant and
  costs no space.
- **No install prefix is ever written in Swift.** roothide relocates rootful
  paths into a randomized bootstrap directory, rootless installs under
  `/var/jb`, and a rootful layout has no prefix. `InstallRoot` derives all
  three from the daemon's own `proc_pidpath`. Anything that needs the prefix
  asks it. An unrecognized or unreadable daemon path refuses startup; only a
  recognized rootful path may produce an empty prefix.
- **The daemon writes wherever root can.** `FileOperations.writableRoot` can
  confine a backend to one folder, and nothing sets it any more — the File
  Provider that did is gone. It stays because it is the fence a future
  single-folder backend would need, and its tests still prove it. A root file
  manager confined to its own bootstrap is not one: `/var/mobile` is outside every
  jailbreak's install root, and refusing to write there reads as "no
  permission" on every operation. What protects the device is `FilaGuard`'s
  destruction list on every layout, and the bootstrap node itself can never
  be destroyed. The trash of a relocated daemon lives under its install root
  (`FileOperations.trashBase`); the app is untrusted UI, and its disabled
  actions are only a courtesy.
- **Archives are made and unpacked by `fila-archive`, never by `filad` and
  never by the app on a device.** libarchive allocates by content size, which
  the daemon's 6 MB cannot hold, and a job in the app dies with the app. So a
  `.compress` or `.extract` job spawns `<install root>/usr/libexec/fila-archive`
  — `ArchiveHelperRun` is the one place the daemon starts a program besides a
  terminal, with an argv of exactly itself, an empty environment and the job as
  JSON on standard input; it refuses everything else. The helper links
  `FilaFormats` and `FilaFileOps`, so its writes go through the same guard and
  the same atomic replace, and `ArchiveJob` is the whole of the work — the
  in-process backend runs the same type when there is no daemon. Progress comes
  back as lines on the helper's standard output and `SIGTERM` is the cancel.
  The password of an encrypted zip travels inside the job and is never logged.
- **Every path is canonicalised before a decision is made about it.** `/var` and
  `/etc` are symlinks into `/private` on every Apple platform; a guard that
  compares an unresolved string is a guard with a bypass. `realpath(3)` first,
  then compare path components. Reject embedded NUL before C conversion so the
  check and syscall name the same path. `FilaGuard.normalize` is defence in
  depth, not a substitute.
- **Destructive operations never follow a symlink.** `lstat`, `O_NOFOLLOW`,
  `COPYFILE_NOFOLLOW`. Deleting a link must delete the link. Restricted writes
  also refuse in-place content or metadata changes to non-directory nodes with
  more than one hard link: another name may be outside the writable root. Atomic
  replacement and unlink can change an inside directory entry without changing
  that shared inode's content; cleanup must not clear its flags first.
- **Writes are atomic.** Same-directory temp file, metadata copied across
  (mode, owner, times, xattrs, BSD flags), then `rename(2)`. A half-written
  system plist is a boot loop. The known cost is that `rename` swaps the inode,
  so hard links to the old file and processes holding it open keep the old
  content — that is a deliberate trade, taken because a truncating write can
  destroy a file the user cannot restore.
- **New user files default to mobile:mobile (501:501), mode 0777.** Copies
  and hard links preserve their metadata, and extraction keeps archive modes.
  Explicit modes remain available for private staging and workspace directories.
  Apply new-file defaults before publication; replacing an existing file keeps
  that file’s metadata.
- **Delete moves to the trash by default.** Same-volume `rename` into
  `<install root>/.fila-trash` on a restricted daemon, or
  `<volume mount point>/.fila-trash` otherwise, is instant and undoable; permanent
  delete is an explicit action, and the default is a setting. The names live in
  `FilaTrash` (FilaProtocol), never the system `.Trash/<uid>`: this is a
  jailbroken device and nothing else owns that layout. The job writes the
  item's origin onto it as the `wiki.qaq.fila.origin` xattr; *Put Back* inside
  the trash reads it and then removes it, so there is no index to drift. Inside
  the trash the browser offers Put Back, Delete Permanently and Empty Trash,
  and opens nothing. Across volumes, publish a complete `copyfile` copy with
  its origin before removing the source; a relocated bootstrap may be on
  Preboot while the source is on a data volume. Put Back uses the same
  cross-volume move and never replaces an occupied origin. Undo matches a
  trash-job UUID plus origin, because inode numbers do not survive copying.
  A read-only trash fails with the real errno and the app offers permanent
  deletion. Cancellation or failed removal retains any published trash copy.
- **iOS 15 is a promise the SDK will break for you.** The floor in
  `Base.xcconfig` says nothing about whether the build runs there: the linker
  believes the SDK's availability metadata, and where that is wrong the app dies
  in dyld before `main` with nothing in the build to warn you. Two shapes have
  already shipped. *One:* naming the SDK's XPC type, array-append or
  connection-error macros in Swift resolves to accessors in
  `/usr/lib/swift/libswiftXPC.dylib`, which arrived in iOS 16 and is linked
  **non-weakly** because its `.tbd` carries no back-deployment metadata — that
  killed 0.1.6 on two users' iOS 15 devices. `FilaXPC` reads the same constants
  through `CFilaXPC`, one C path on every OS so the version tested is the
  version that runs, and the overlay stays weakly linked and unused. *Two:* an
  SF Symbol newer than the floor is not an error anywhere —
  `UIImage(systemName:)` returns nil and the control draws nothing. `make check`
  warns on the first (only below iOS 16; a raised floor is entitled to the
  overlay) and fails on the second, against CoreGlyphs' own availability table.
  Before a release, prove the product with `otool -L | grep -v ', weak)'`,
  `nm -m | grep 'weak external'` and `vtool -show-build` on every embedded
  framework — the same audit lives in
  `../platformize-app-ios/scripts/audit-ios-floor.sh`.
- **Versions live in `Configuration/Version.xcconfig` only** (edit via
  `make set-version`). xcconfigs attach at project level; a target-level
  `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in the pbxproj silently
  shadows them and ships the wrong build number. `make check` rejects this, and
  the same applies to `IPHONEOS_DEPLOYMENT_TARGET` in `Base.xcconfig`.
- **No project generators.** `Fila.xcodeproj/project.pbxproj` is hand-written
  and checked in (objectVersion 77, file-system-synchronized groups — a file
  added under `Fila/` or `Filad/` joins its target automatically; `Packages/FilaKit`
  is a local Swift package reference instead, governed by its own `Package.swift`).
  Never introduce XcodeGen/Tuist. `make check` fails if Xcode rewrites
  `objectVersion` on a GUI save; revert that line.
- **The daemon being absent is never surfaced as an error.** `filad` is
  on-demand: a miss means launchd has not spawned it yet, and a jailbreak that
  just resprang takes a moment. There is nothing a user could do about it, so
  the app keeps retrying and keeps saying *Connecting…*. Do not add a failure
  screen, and do not "fix" the simulator by faking the daemon in the app.
- **No new dependencies without a reason that survives the ladder.** The deb
  still has no `Depends` beyond `firmware`, `uikittools` and `launchctl`.
  What is linked in is app-side, and each item replaced code that was never
  going to be written well by hand: `libarchive.xcframework` (7z, rar, iso, xar,
  and the filter chain), `libghostty-spm` (the terminal),
  `Runestone.xcframework` (the text editor's tree-sitter highlighting; ~38 MB of
  parse tables, shown to the user, chosen), swift-nio with
  swift-nio-transport-services (the WebDAV framer; Transport Services wraps an
  `NWListener` and gives the channel backpressure — see `WebDAV-Library.md`),
  MachOKit (the Mach-O inspector's parser, inside `FilaFormats`), SnapKit
  (layout), Then (view setup), AlertController (the one alert card), and
  SPIndicator (the toast chrome under `Toast`). One dependency is vendored
  rather than resolved: `Packages/SMBClient`, because listing a remote
  directory one server response at a time needs one method inside the module
  and every primitive under it is `private`. `FILA-VENDOR.md` beside it
  records the revision, the single added method and what was left out; keep
  it true when the copy moves. Versions elsewhere are declared as `from:`
  minimums, not exact pins. A new dependency also owes `Licenses/` an
  entry — `Scripts/collect-licenses.py` collects them and
  `Licenses/Compatibility.md` records why each licence is compatible.
  **No third-party dependency links into `filad`.** The next library needs the
  same argument: what it replaces, and why the hand-written version would be
  worse rather than merely longer.

## Layout

- `Fila/` — the app. `main.swift` (manual `UIApplicationMain`) + `Application/`
  (delegates) + `Interface/<feature>/` + `Resources/`. UIKit is the shell and
  the file list will stay a collection view; SwiftUI is used inside individual
  screens.
  App source is organized by ownership:
  - `Application/State/` — `AppPreferences`, `FileClipboard`, `BrowserTabStore`
    and shared app-list options; `System/` owns capability availability.
    `BackendComposition` is where the module frameworks are discovered,
    `AppBackendShell` is the host they are given, and `SidebarModel` merges
    what they contribute.
  - `Services/Files/` — `FileSession`, `DirectoryReader` and `FileSearch`;
    `Transfers/` owns `OperationCenter` and downloads; `Sharing/` owns
    `FileSharingServer` and `WebDAVFileService`; `Installation/` owns
    `DebianPackage`. Installed-app discovery and IPA installation are **not**
    here — they belong to the `FilaApplications` module.
  - `Interface/` groups screens and views by feature. `Navigation/` owns the
    shell and links; `FileActions/` owns shared action/destination panels;
    `Feedback/` owns errors and toasts; `Shared/` holds reusable UI including
    `FilePresentation`. A backend's own screens live with the backend, in
    `Frameworks/<Name>/`, not here.
  - `Shortcuts/` — App Intents. A second entry point into the same operations
    the browser uses, `FilaGuard` and `OperationCenter` included, so a change
    to a destructive path has two call sites to check, not one.
  `FileSession.operations` directly owns the single `OperationCenter`; do not
  restore the removed `JobCenter` forwarding layer or its failure mailbox.
  Keep filenames aligned with their owning type; independently navigable
  extensions use `Type+Concern.swift`. Keep wire values, UserDefaults keys and
  Codable fields stable when renaming Swift symbols.
- `Filad/` — the daemon, product `filad`. `main.swift` + `Server/`
  (`DaemonServer` listener, `PeerAuthenticator`) + `System/` (`InstallRoot`,
  the libSystem shims).
- `Packages/FilaKit/` — the local Swift package. Every module's *source* lives
  here, whatever image it ends up in, and every module is testable on the Mac:
  `FilaProtocol` (the wire vocabulary and `FilaGuard`), `FilaFileOps` (the root
  side's POSIX calls and jobs), `FilaLog`, `FilaClient` (the in-process backend
  and `DescriptorIO`), `FilaPrivileged` (the XPC link — `DaemonLink`,
  `DaemonFileService`), `FilaBackendKit` (the backend contract: `FileService`,
  `Backend`, `BackendModule` and the registry), `FilaBackendUI` (the shared list
  base, `TabContentViewController` and `FilaUI`), `FilaFormats` (readers and
  writers that allocate by content size, over a descriptor the daemon handed
  back; libarchive and MachOKit live here), `FilaMedia` (AVFoundation and
  ImageIO over the same descriptors), `FilaTerminal` (the pty pump and
  libghostty), `FilaRemote` (the WebDAV server and URL download),
  `FilaApplications`, `FilaMusicLibrary`, `FilaSMB`, and the `C*` shims.

  The daemon links **only** `FilaProtocol`, `FilaFileOps` and `FilaLog` — that
  list is a budget, not a habit, and everything else is app-side because
  launchd caps the daemon at 6 MB. SnapKit and Then may be imported by UIKit
  modules and by nothing the daemon links.

  The package used to be `Shared/`; the reason it moved is that the code that
  can destroy the user's filesystem — the actual `copyfile`/`removefile` jobs,
  not just the guard — could not be tested without building the daemon, and
  now it can: nearly every module has a `swift test` target under
  `Packages/FilaKit/Tests/`. Core code must build and test on macOS with plain
  SwiftPM, without building the iOS app or daemon. UIKit-only code stays behind
  `canImport(UIKit)`; the host harness does not create a macOS product.
- `Frameworks/` — the dynamic images the app actually links. Six Xcode
  framework targets, each compiling package sources rather than depending on a
  package product:
  - `FilaCore` is one file of `@_exported import` and nothing else. Every
    FilaKit product is linked **once**, here, and re-exported: `import
    FilaClient` in the app resolves to the copy inside `FilaCore.framework`.
    That is why the app target itself links only Runestone and SPIndicator.
    Linking a package product from two images would give the process two
    copies of every class, and Swift conformance lookup and the Objective-C
    runtime both misbehave on duplicate definitions.
  - `FilaLocal`, `FilaPrivileged`, `FilaApplications`, `FilaMusicLibrary` and
    `FilaSMB` are the backend modules: the module's screens, its
    `FilaBackendModule.plist` manifest and its own string catalogue, over the
    matching `Packages/FilaKit/Sources/<Name>` directory.

  **A backend module lives in two places on purpose.** The package target is
  the source and the `swift test` surface; the framework target compiles that
  same directory. `FilaPrivileged`, `FilaApplications`, `FilaMusicLibrary` and
  `FilaSMB` are deliberately **not** package products — a product would drag
  its whole closure into the framework beside the copy already in `FilaCore`.
  Read the comments in `Package.swift` before changing that shape.

  A module is discovered at launch by its manifest, not by a switch statement:
  `BackendModuleDiscovery` reads `FilaBackendModule.plist` out of every
  embedded framework and `BackendRegistry` registers what it finds. A module
  that is not linked is not registered, and a screen that is not registered is
  not offered — which is the whole mechanism behind the two compositions.
- `FilaArchive/` — `main.swift` for the `fila-archive` helper described above.
- `FilaSaveAction/` — the *Save to Fila* share-sheet extension, the only
  appex, with its own entitlements and its own catalogue. It carries the
  configured App Group, and both packagers sign and verify it.
- `Packages/SMBClient/` — the vendored SMB library; see `FILA-VENDOR.md`.
- `Tests/` — what does not fit `swift test`: `test-packaging.py` and the
  music-import fixtures. `Licenses/` — one directory per dependency, collected
  by `Scripts/collect-licenses.py`, with `Compatibility.md` recording why each
  licence is compatible.
- `WebUI/` — the browser frontend of the WebDAV server: React + webpack,
  TypeScript, no hand-written HTML. It is pure static output (`dist/index.html`,
  `app.js`, `app.css`) and talks to the backend over WebDAV only. The app
  target's *Build Web UI* phase (`Scripts/build-webui.sh`) runs webpack and
  copies `dist/` into `Fila.app/WebUI`; `FileSharingServer` hands that
  directory to `WebDAVServer.Configuration.webRoot`, and the server serves
  `index.html` for a directory GET and the assets under the reserved
  `/_fila/` prefix, with a CSP that allows nothing inline. `FilaRemote` has
  no bundled resources; the harness serves a stub web root. To look at it on
  the Mac: `FILA_WEB_DEMO=1 swift test --package-path Packages/FilaKit
  --filter WebUIDemo` serves `WebUI/dist` live, so `npm run watch` plus a
  reload is the iteration loop. Design: Cloudflare Kumo — white/black,
  one orange accent, 4 px radius, dense rows.
- `Configuration/`, `Packaging/`, `Scripts/` — build inputs; see below.
  `Scripts/` is larger than the few names this document quotes: everything
  `make check`, `make deb`, `make ipa` and the release workflow enforce lives
  there, and `.github/workflows/` (`release.yml`, `pages.yml`) is what runs
  them. Read the script before assuming a rule is only advice.
- `Documentation/Architecture.md` for the design in full,
  `Documentation/Roadmap.md` for what was deliberately deferred and why,
  `Documentation/Packaging.md` for the four wrappers, and
  `Documentation/Listing-Latency.md` for where a directory listing's time
  actually goes, measured rather than guessed.

There is deliberately **no CLI target**: the app is the only client. Its XPC
link to `filad`, `DaemonLink`, lives in `FilaPrivileged` rather than beside its
callers in the app, so the backend can be tested through the same host harness.

## App UI libraries

Fila is UIKit. iGhostVT is SwiftUI, so it redrew Lakr233/AlertController as
`AlertCardView`; Fila uses the package itself. The four libraries below are
the only way their jobs get done. `make check` greps `Fila/`, `Frameworks/`
and the UIKit package modules (`FilaBackendUI`, `FilaApplications`,
`FilaMusicLibrary`, `FilaSMB`, `FilaTerminal`) for the APIs they replace, and
fails the build when one comes back. A screen under `Frameworks/` is policed
exactly like a screen under `Fila/`.

Configure AlertController once at launch, in `AppDelegate`, before any
scene exists:

```swift
AlertControllerConfiguration.accentColor = UIColor(named: "AccentColor") ?? .systemBlue
AlertControllerConfiguration.alertImage = UIImage(named: "cat.fill")
```

Permanent deletion may temporarily set the accent to system red while constructing
the standard AlertController, then restore it synchronously. Do not leave the
package's default red accent on other alerts.

### Then — construct and configure

A view that needs more than one property is born configured, not assigned
line by line after the fact:

```swift
let label = UILabel().then {
    $0.font = .preferredFont(forTextStyle: .body)
    $0.textColor = .secondaryLabel
    $0.numberOfLines = 0
    $0.adjustsFontForContentSizeCategory = true
}
view.addSubview(label)
label.snp.makeConstraints { make in
    make.edges.equalToSuperview()
}
```

- `then` on a newly constructed object (it returns `Self`).
- `do` on a view that already exists (`collectionView`, `self.view`, a
  cell's `contentView`).
- `with` on a value type (`UIButton.Configuration`, `UIEdgeInsets`,
  `NSCollectionLayoutSection`).
- One property is one assignment. Do not wrap a single `textColor =` in
  `then` just to have used Then.
- Constraints stay outside the `then` block, after `addSubview`. SnapKit
  needs the view in the hierarchy; mixing the two hides that.

### SnapKit — every constraint

`NSLayoutConstraint.activate`, `anchor.constraint`, and
`translatesAutoresizingMaskIntoConstraints = false` do not appear in any
policed root. SnapKit turns the mask off itself.

Pin to the guide that is actually the edge. `make.edges.equalToSuperview()`
is the full-bleed case, not the default:

```swift
collectionView.snp.makeConstraints { make in
    make.top.leading.trailing.equalTo(view.safeAreaLayoutGuide)
    make.bottom.equalToSuperview()
}
stack.snp.makeConstraints { make in
    make.top.equalTo(view.safeAreaLayoutGuide)
    make.leading.trailing.equalToSuperview()
    make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
}
```

A stored constraint that later changes its constant is a SnapKit
`Constraint`, updated in place — not deactivated and rebuilt:

```swift
pathBarWidth = make.width.equalTo(FilaUI.minimumTapTarget).constraint
pathBarWidth?.update(offset: width)
```

`.priority(.high)` is `UILayoutPriority.defaultHigh` (750). Use
`multipliedBy` for the 0.55 app badge and the 0.85 tab thumbnail.
`UIScrollView.contentLayoutGuide` / `frameLayoutGuide` and a list cell's
`separatorLayoutGuide` are SnapKit views; pin to them the way the old
anchors did.

`UIStackView` still owns its arranged subviews. SnapKit pins the stack
and any overlay (badges on an icon), not every label inside the stack.
`UITableViewController` still owns its table; do not pin `tableView`.

Two frame layouts stay frames, because they are not constraint problems:
the image view inside the zooming `UIScrollView`, and the tab-switcher
snapshot / mask during the overview animation. Everything else that
today uses `autoresizingMask = [.flexibleWidth, .flexibleHeight]` or
manual `layoutSubviews` frames (including `LogRowCell`) becomes SnapKit.

### AlertController — the one alert

There is no `UIAlertController` and no `UIAlertAction`. Confirmations,
failures, action-sheet choices, and delayed progress are the same card.
iGhostVT's rule holds: every action dismisses first, then its handler
runs, through `context.dispose { … }`. Cancel disposes and does nothing.

```swift
let alert = AlertViewController(
    title: "Delete Anyway?",
    message: "This cannot be undone."
) { context in
    context.addAction(title: "Cancel") {
        context.dispose()
    }
    context.addAction(title: "Delete Anyway", attribute: .accent) {
        context.dispose { self.startDelete(paths) }
    }
}
present(alert, animated: true)
```

Title, message, placeholder, and action titles are
`String.LocalizationValue`, and the literal must be **wrapped in the
initializer** — `String.LocalizationValue("Enter Password")`, never the
bare `"Enter Password"`:

```swift
context.addAction(title: String.LocalizationValue("Cancel")) {
    context.dispose()
}
```

A bare literal at one of those arguments compiles and runs, and Xcode's
extractor records nothing. It was measured: the same literal is extracted
through `String.LocalizationValue(...)`, through a typed local, and
through `String(localized:)`, and is invisible only when written straight
at the argument and converted implicitly. Forty-two keys got in that way,
survived on `extractionState: manual`, and would have shipped English in
twelve languages the moment someone believed the marker was cruft.
`Scripts/check-localization.sh` fails the build on a bare literal at
these five labels.

The package also has a `String` overload marked `@_disfavoredOverload`:
any already-resolved string becomes the lookup key, so a raw English
`String` variable ships English on a Chinese device. Computed copy
(`FailureMessage.text(for:)`, a path) is the `String` overload on
purpose — it is not a catalogue key.

The package has `.normal` and `.accent`, not `.destructive`. Permanent
file deletion uses `PermanentDeleteConfirmation`, which constructs the standard
package alert under a temporary system-red accent and restores the default.
Every alert has a visible Close/Cancel/OK action;
`context.allowSimpleDispose()` only enables Escape and does not add a button.
Deletion icons use the standard `trash` symbol, never `trash.slash`.

One line of input is `AlertInputViewController` (rename, new folder, jump
to offset). Do not revive `addTextField` to set `keyboardType`. It comes
from the AlertController package, not from this repository — grepping the
tree for it finds call sites and no definition.

There is one progress card, `OperationCoverViewController`, hosted by
`AlertViewController(contentViewController:)`: the package's own progress
alert has no buttons and its content controller is internal, so it cannot be
subclassed into one, and `Scripts/check-ui-libraries.sh` fails on
`AlertProgressIndicatorViewController` anywhere. The card renders a
`Source` — a job's row in `OperationCenter`, or work run under
`ProgressCard.run` (a module's under `BackendShell.withProgress`) — so both
look and behave alike: revealed only after `StatusView.revealDelay`,
Continue always (the card closes, the work finishes), Cancel only where the
work can stop part-way without leaving anything half done. `ProgressCard.run`
and `BackendShell.withProgress` take `cancellable:` explicitly at every call
site; installd, and music-library imports, saves and deletes, are not.
Cancel makes `run` throw `CancellationError` once the work has stopped, and
`run` returns only once its card is gone — the next alert is never presented
into a dismissal. `JobCover` is the wait for that: `settle`/`settled()`.
Blocking descriptor copies go through `DescriptorIO.blocking`, which carries
the caller's cancellation into the copy loop.

Copying or moving into a folder — Paste, a drop, an import from another app —
is `FileDelivery.deliver` over `FileReference`s (a local path, or a location
on a share): the native job between local folders, `OperationCenter.transfer`
when a share is involved, one replacement question and one failure report
for all of them. Local files go to a share by path, through the local layer
rooted at their folder, because a sandboxed local root (Documents) contains
neither the Inbox nor the app's workspace. A drag between Fila's screens
carries a `FileReference` as its local object; every screen proposes a drop
with `FileReference.proposal` and hands it to `FileDrop` (modules:
`BackendShell.drop` for a folder, `receiveFiles` for a screen that takes
files of given types, like the music library — a share's or another app's
files are fetched first). Do not add a second copy path for a new screen. A
card whose answer is awaited is `CardQuestion.ask`; something arriving from
outside its screen presents through `TopPresenter`, which never stacks on a
progress card.

A message with nothing to decide — a result, a refusal — is
`presentMessage(_:message:)`, one OK; do not build the same card by hand.

A card does not need a popover source. `anchor(_:to:)` remains for
share sheets and document pickers, not for alerts.

### SPIndicator — only through `Toast`

Transient "copied / undone / finished" feedback is `Toast.show`. Do not
construct `SPIndicatorView` at a feature call site, and do not present
an alert for something that has no question and no button. Errors that
need a title, a reason and Close stay AlertController; `FeedbackAlert` finds
the active presenter when the original screen is gone. `Toast` is success-only:
a single line with SPIndicator's `.done` preset, without custom icons or subtitles.
**Nothing on it is pressable.** An indicator has no room for a control that
reads as one, and "Moved to Trash · Put Back" was a label people took for a
button. The same rule holds for the task rows in `TransfersViewController`:
they are receipts, Cancel lives on the job's own progress card, and a
destructive inverse is not one tap away in a list of past results.

`Fila/Interface/Feedback/Toast.swift` is the only file that imports
SPIndicator. It already queues and hosts a passthrough window. Extend
that wrapper if the chrome is wrong; do not fork a second presenter.

### Grouped rows and alert cards — two rules `make check` enforces

A settings-style key/value row is **one line**: `UIListContentConfiguration
.valueCell()`, title leading, value trailing in the secondary colour, chevron
if it pushes. `subtitleCell()` stacks the value under the title and is for
content lists only — a file row with its size, a plist key with its summary,
a status card with a hero icon — and those files are an allowlist in
`Scripts/check-ui-libraries.sh`. A new two-line row anywhere else fails the
check; either make it a value row or argue the file onto the list.

Every `AlertViewController` and `AlertInputViewController` carries a
non-empty `message:` under its title. A bare title over a text field reads
as unfinished; say what the value is for, or what the choice does, in one
sentence. The same script fails on a missing or `""` message.

## Build & verify

- `make harness` — `swift test --package-path Packages/FilaKit`, then
  `Scripts/test-music-import.sh`. No device, no simulator. Run this before
  anything else; it is where a guard mistake, or a copy that loses an xattr,
  gets caught.
- `make check` — project and packaging validation: the ten Xcode targets must
  all exist, versions and the deployment target must live in `Configuration/`,
  the string catalogues must match what the compiler extracted, and the
  UI-library grep must come back empty (no `UIAlertController`, no
  `NSLayoutConstraint.activate`, no SnapKit-bypass
  `translatesAutoresizingMaskIntoConstraints`, no `SPIndicatorView` outside
  `Toast.swift`). Note that outside CI it *rewrites* the tree:
  `Scripts/remove-stale-strings.py` prunes stale catalogue keys unless `CI` is
  set, so a `make check` can leave a diff.
- `make compile` / `make compile-sandboxed` — build only, no packaging. This is
  what CI runs beside `harness` as three parallel jobs.
- `make build` — unsigned `Fila.app` + `filad` + `fila-archive` for iPhoneOS
  (runs `check` and `harness` first). It, `make sim` and `make vphone` bump
  `CURRENT_PROJECT_VERSION` first, so `Version.xcconfig` comes out of a build
  dirty by design.
- `make sim` — Debug build onto the booted simulator. There is **no daemon**
  there and there cannot be: `launchd_sim` prefixes every job's program path
  with the runtime root, which is a sealed read-only volume, so no launchd job
  can ever point at our binary and the Mach service is never registered.

  The simulator is nevertheless a real test surface, and what it stands in for
  is the sandboxed `.ipa`: `LocalFileService.processReach` is pinned to
  `.container` under `targetEnvironment(simulator)`, so **both compositions
  run the sandboxed local backend there** and browse the simulated app's own
  Documents directory — listing, viewers, properties, search, the whole shell,
  over the same root a sideloaded copy has. The simulator process itself is
  not sandboxed and could read the Mac's filesystem, but no wrapper of this
  app ever runs in that shape, so it is not offered. What the simulator does
  **not** exercise is anything privileged: the XPC hop, the authenticator, the
  daemon's guard, a descriptor opened as root, the full filesystem root. Use
  it for everything visual and then prove the privileged half on the vphone.

  There used to be a Mac Catalyst build here — `make mac` — and it was the one
  place the real daemon ran off-device. It is gone, deliberately: this is not
  software for a Mac. The cost is worth stating rather than rediscovering:
  **a jailbroken iOS device or vphone is required to run `filad`.** The
  in-process backend covers the shell, not the privileged XPC path.
- `make deb` — build, ad-hoc sign with ldid, package for `FLAVOR` (default
  `roothide`, `iphoneos-arm64e`, rootful paths; `FLAVOR=rootless` packages the
  same binaries under `/var/jb` as `iphoneos-arm64`), then verify the archive
  with `Scripts/verify-deb.sh`. `make deb-all` builds both.
  Path helper: `make print-deb-path [FLAVOR=rootless]`.
- `make tipa` / `make ipa` — the app alone, no `filad`, packaged as
  `Payload/Fila.app` by `Scripts/package-ipa.sh` and checked by
  `Scripts/verify-ipa.sh`. The `.tipa` is the full `Fila` target, ad-hoc
  signed with the same `Packaging/Fila.entitlements` as the deb (TrollStore
  applies what it finds embedded). The `.ipa` is the **`FilaSandboxed`**
  target — `make build-sandboxed`, its own DerivedData beside the full one,
  and **no build-number bump of its own**, so it carries the number the last
  full build took and never moves `Configuration/` out from under that
  build's receipt — and carries **only the configured standard App Group**
  entitlement. The
  user approved this shared-container workflow: the sideloading tool must
  provision the same `APP_GROUP_IDENTIFIER` for the app and the embedded
  Save action when re-signing. Jailbreak/private entitlements stay excluded
  from the ordinary IPA and from the extension.
  Path helpers: `make print-tipa-path`, `make print-ipa-path`.
- `make packages` (`make all`) — all four in one go: the full build, then the
  sandboxed build at the same build number, then every wrapper.
- **One shell, two compositions — and within a composition the backend is
  resolved at runtime, never at build time.** `Fila` and `FilaSandboxed` are
  two app targets over the same `Fila/` sources and the same shared
  frameworks; what differs is the link line. Both embed `FilaCore` — that one
  is not a backend and is never excluded. `Fila` then links and embeds every
  module framework (`FilaLocal`, `FilaPrivileged`, `FilaApplications`,
  `FilaMusicLibrary`, `FilaSMB`) as `-needed_framework` startup dependencies
  and serves the `.deb` and the `.tipa`; `FilaSandboxed` links `FilaLocal`
  and `FilaSMB` alone and serves the `.ipa`, so the archive a free developer
  account re-signs contains no private API. `FilaSMB` is public API
  throughout — Network.framework, CommonCrypto and the vendored
  `Packages/SMBClient` — which is why it ships in both. Never add a build flag, a compilation condition
  or a per-packaging source variant to tell wrappers apart: a module that is
  not linked is not registered, and a screen that is not registered is not
  offered. The one platform condition is the simulator's container pin in
  `LocalFileService.processReach`, which is about where the process runs,
  not which wrapper it is. `Scripts/verify-composition.sh` reads the
  composition back out of every packaged bundle — frameworks, load
  commands, and the class and private-framework strings of the excluded
  modules — and both packagers fail on the wrong one; its `shared` list is
  the statement of what both compositions must carry.

  A **new module framework joins the sandboxed composition** by being added to
  `FilaSandboxed`'s Frameworks, Embed Frameworks and `-needed_framework` lists
  and to that `shared` list — three places and a verifier, on purpose. A module
  that should stay out of the `.ipa` is simply not added, and needs nothing.

  `DaemonLink` holds two services — `DaemonFileService` over XPC and
  `LocalFileService` calling `FilaFileOps` in this process — and chooses once,
  at the handshake. `Hello.backend` is the only honest answer to "am I running
  as root", and it is an enum carrying the install root rather than a flag
  beside it, so a caller cannot read the polarity backwards.

  **The selection rule is a grace period, and it is deliberately not a
  timeout and deliberately not a count.** Not a timeout, because a jailbreak
  that has just resprung takes seconds to register the Mach service and an app
  that gave up on a timer would silently demote a root file manager to an
  unprivileged one — being demoted without being told is worse than waiting.
  Not a count of attempts, because a count means whatever the caller's polling
  cadence makes it mean: `ready()` asks once a second and `ready(within:)` four
  times a second, so the same three misses were three seconds of grace for one
  and three quarters of a second for the other. It is a duration, the clock
  starts at the first miss rather than at construction, and a build that ships
  a daemon beside its bundle never falls back at any elapsed time.

  Corollary worth keeping: a caller that means "is the daemon the live backend"
  must ask `hello().isPrivileged`, never the construction-time
  `daemonIsInstalled`. The two differ exactly where it matters.
- `make install` — build for `FLAVOR` and update an existing installation
  through `Scripts/install-device.sh`. Its default transport is `iproxy 2333 22`;
  `DEVICE_HOST`, `DEVICE_PORT`, `DEVICE_USER` and `DEVICE_PASSWORD` support an
  explicitly authorized device. The package's postinst boots the daemon and
  runs `uicache`. The updater derives the real bootstrap from the installed
  package, so first installation still uses the device's package installer.
  The script's optional `--launch` argument closes the old Fila before installation
  and asks iOS to open the new one afterward. Confirm the installed payload and actual launch: a locked
  iPad can accept installation while refusing to launch the app.
- `make vphone` — incremental Debug build and signing, then serve one `.deb`
  from a dedicated temporary directory over HTTP. No SSH and no VM restart.
  The running VM's native socket places the download URL in its clipboard;
  in Safari, paste and download. Open Files → Recents, tap `Fila.deb`, then
  install it in Sileo. Close the old Fila in the App Switcher and reopen it;
  check the changed features.
  The script neither installs nor claims a test result. Ctrl-C
  stops the server and removes its temporary copy. Same-version rebuilds may
  reuse Sileo's old APT cache: remove only the previous Fila `.deb` inside the
  writable bootstrap via Fila before reinstalling. `VPHONE_HTTP_HOST` defaults
  to `192.168.64.1` and `VPHONE_HTTP_PORT` to `8765`; the server requires a specific host IPv4
  address, never `0.0.0.0`. `VPHONE_SOCKET`, `FLAVOR` (default `rootless`),
  `DERIVED_DATA`, and `DEB_OUTPUT` overrides are supported. `--test` and
  `make vphone-test` were removed because installing and testing require UI
  confirmation. This development target skips release gates; run
  `make harness` and `make check` before shipping.
- Packaging inputs are templates: `@PREFIX@` in
  `Packaging/wiki.qaq.filad.plist`, `DEBIAN/postinst` and `DEBIAN/prerm` is
  substituted at package time, `@FLAVOR@` and friends in `DEBIAN/control`.
  `Packaging/Fila-Info.plist` is merged into the generated Info.plist and holds
  only the keys Xcode has no `INFOPLIST_KEY_*` setting for.
- Both packagers ad-hoc sign every library under `Fila.app/Frameworks` first
  (`Scripts/sign-frameworks.sh`). The unsigned build leaves the Swift
  compatibility dylibs the toolchain copies in for older OSes carrying Apple's
  own signature, which a jailbroken iOS 18 refuses outside the system: dyld
  halts the app at launch with "code signature invalid", and iOS 26 never
  loads the library, so the crash shows only on the older device.
- Both packagers re-read the entitlements back out of the signed binaries and
  fail on them. That check exists because a lost — or kept — entitlement does
  not break the build: it makes the daemon silently refuse the app, or the
  user's own signing step refuse the archive, which looks like a bug anywhere
  but where it is. The two archives fail in opposite directions, so
  `verify-ipa.sh` checks jailbreak entitlements for absence on one side and
  presence on the other. Both wrappers require a matching standard App Group
  on the containing app and on the one embedded extension, `FilaSaveAction`,
  which shares that container. `Scripts/sign-extensions.sh` signs it,
  `Scripts/verify-deb.sh` requires the appex in the payload, and
  `verify-save-action.sh` reads the entitlements back out of both the app and
  the extension — the drift that used to go uncaught is caught now.

### Review gate on file operations

Any change that touches the file layer — the daemon's operations, the jobs, the
guard, path handling, anything that opens, moves, writes or deletes — goes
through `/code-clarity` and then `/code-review` before it is called done. Not
optional, and not only for large diffs: this is the code that destroys the
user's data when it is subtly wrong, and subtly wrong is exactly what a fast
read misses. Interface, packaging and build changes do not need it.

`FileClipboard` completion belongs to the snapshot that started the transfer. Copy
stays reusable; cut is consumed only after success. A failed batch does not
identify which source roots moved, and a later `ENOENT` does not prove that
this job moved them. Preserve the failed selection instead of guessing.

### Temporary files

`FileSession` owns app-created share, download, nested-archive, log-export
directories. Both backends use the app's system temporary directory under
`wiki.qaq.fila/<process UUID>`. Never create scratch workspaces at the filesystem
root or under the install root. The parent and workspaces stay app-owned 0700.
Verify an existing parent's type, owner, permissions and canonical path rather
than changing an unknown directory's ownership.

Each consumer removes its own UUID directory when finished, including share
cancellation and failed preview handoff. Startup lists the dedicated parent
before deleting stale UUID directories and waits for each delete job's result.
Normal exit makes a synchronous best effort to remove the whole workspace.
SIGKILL cannot run cleanup: the next startup removes its leftovers. Do not turn
an accepted cleanup job into a claimed completion.

Atomic save, copy, extraction, ZIP publication and WebDAV publication still
require a temporary beside their destination; daemon writes remain inside its
writable root. Preserve those atomic boundaries and clean failed publications.
`URLSessionDownloadTask` also owns a system-managed temporary location whose
placement is not configurable; its completed file moves into the app workspace.

libghostty's generated terminal configurations stay app-local under
`<system tmp>/<bundle identifier>/ghostty-config-<UUID>.conf`, including with
the privileged backend. `TerminalTemporaryFiles` prepares this parent as 0700
and unlinks only those direct configuration entries before any controllers
are created and on termination. Never remove the parent: the local backend
also keeps its UUID workspaces there. Controllers still remove their own files
on replacement and destruction; startup covers force-quits. Old loose configs
outside this directory are not swept.

The device updater owns a separate, exclusive `.fila-install.XXXXXXXX` directory
under the installed daemon's resolved bootstrap. It gives that directory to
the invoking user (mobile by default) with mode 0700. Its exit trap attempts to
remove only its fixed `package.deb` and empty directory and reports cleanup
failure; SIGKILL cannot run the trap. Host build/package directories are
separate from this device temporary-file policy.

### Where things get tested

Run the macOS harness first. Use the simulator when useful for local UI work,
and a running **vphone** (or another jailbroken device) for the real privileged
backend, entitlements, launchd and bootstrap layouts. Vphone testing uses the
native socket by default, or SSH when explicitly authorized, and does not restart the VM. Install on a physical
device only when its owner authorizes that target. Keep destructive test
fixtures in the app-owned temporary workspace.

SourceKit diagnostics in this repo are frequently stale false positives around
`PBXFileSystemSynchronizedRootGroup` — trust `xcodebuild`, not the editor.

Runtime self-tests and fixtures are not shipped. Run the host harness and use
focused device checks for changed features. `Scripts/vphone-ui.py` provides
native VM interaction; SSH may be used when the user explicitly authorizes it.
Do not record a browser in Recents until it actually appears; creating hidden
controllers for restoration or tests is not a visit.

### Navigation chrome

Every screen that lives in a tab subclasses `TabContentViewController`
(`FilaBackendUI`; `TabContentTableViewController` for a table page) and
fills slots, never assembles a bar. **Top bar:** Back and Places on the
leading side, supplied by the shell from the destination stack and the split
view's state; the title; the screen's `trailingNavigationItems` — usually one
`actionsItem(menu:)` ellipsis. **Bottom bar:** search leading
(`wantsSearchButton` with `search()` for the local browser's button, or
`installSearch(_:)` for a search controller, whose field lands there on
iOS 26), the breadcrumb in the centre, and the Tabs control trailing. Tabs
is never anywhere else, and never in a menu. The Search, breadcrumb and
Tabs objects are one `TabContentBar` per tab, made by
`TabNavigationController` and set as every page's `bar` before the push
starts: a page that put fresh items on the bar would make UIKit blur the
whole bar out and in with the transition, and the same objects on both
pages leave it standing. A sheet or a picker — which the shell never gave a
bar — shows no Tabs and, with nothing else set, no bottom bar. A mode that
owns the whole bottom bar (selection) uses `setToolbarOverride(_:animated:)`.

The breadcrumb is one `PathBarView` on every page, read through
`TabContentDecorationSource`, the way a table reads its data source: a
screen that knows where it is conforms itself (a folder, a share, a
catalogue and its entries); a screen about something else is given a
source — `LocalPathDecoration` for a viewer, Search, Properties or a
terminal on a local path, `DetailDecoration` for a page pushed with
`pushDetail(_:)` about part of another page, or the share's crumbs continued
under a remote snapshot. A catalogue's first crumb is its sidebar artwork
and name (`BackendShell.rootArtwork`). Call `reloadDecoration()` when the
answer changes; never draw a second breadcrumb.

Every pushed screen must have all of its bar button items ready before the
UIKit push starts: build screen-owned items in initialization. Viewers
finish format detection and prepare their child controls before being pushed.
Appearance callbacks may refresh enabled states and menus; they must not
remove and recreate the initial buttons during the transition.

The navigation bar holds the native, stable title and icon controls only.
Do not wrap titles or ordinary content in extra Liquid Glass capsules. Do not use
`navigationItem.prompt` for permission, editing, connection, or progress state:
it adds a second row and shifts the content during navigation. Put necessary
status in the screen's content or the existing settings section. File actions
belong in the shared `ellipsis` menu (not `ellipsis.circle`); preserve the same
file operations in previews and editors as in the browser.

Use the shared Save To folder panel for destinations rather than a sheet with
only a raw path field. Unsupported plist leaves must not make readable siblings
disappear; disable editing when the complete document cannot round-trip safely.

Use `FilaUI` tokens for spacing, type and icon sizes. Breadcrumbs size each
label from its actual text width, with equal text-to-chevron gaps; never give
short and long names equal-width slots. Locations uses `bookmark`; the tabs
control has no count. On iOS 26, group only the related bottom actions. On
older systems, use five ordinary buttons separated by equal flexible spaces.

**Every form sheet is `FilaUI.formSheetSize` (555 × 555).** Present through
`presentAsSheet` or `presentAsFormSheet` in `UIViewController+Sheet.swift`
and never set a `preferredContentSize` on a sheet of your own: settings, a
server's setup, the compress form and the pickers are one size, so a sheet
replacing another does not step. The size is applied once, to the presented
navigation controller, at the moment of presentation — never in a screen's
initializer and never on a pushed subpage, because a child that changes its
content size mid-push makes the sheet resize under the transition. Popovers
keep their own size.

### The sidebar: pictures, never symbols, and no forms

**The sidebar never draws an SF Symbol.** Every row — the presets, a
favourite, a mount, a catalogue root, a saved server — shows a picture: the
OS's own folder or app where the row is one (`BackendRoot.artworkName`
`folder` and `application`, through `FilePresentation.Icon.named`), and
otherwise a piece of artwork under `Assets.xcassets/FileIcons`, produced by
`Scripts/make-file-icons.swift` from the Mac's `CoreTypes.bundle` (a saved
server is `GenericSharepoint`, the shared-folder icon Finder uses for a
mounted share). That artwork is Apple's and shipping it is redistribution, so
the set is kept to what iOS has no picture of — the places, the trash, the
link and favourite badges — and each is a candidate for replacement, never a
precedent. A glyph among pictures reads as a control, which is what
*Add SMB Share…* with a `plus.circle` looked like. `BackendRoot.artworkName`
is therefore required and there is no `symbolName`; a backend that needs a
new picture uses the OS's first and argues for artwork second.

**Neither does anything that pictures a file.** A file, folder, bundle,
archive entry or app — a row, a grid cell, a placeholder, a menu entry that
opens a location — is the OS's own picture, drawn at runtime by `DeviceIcons`
through `FilePresentation` (or `BackendShell.fileIcon` from a module): the app
ships no file-type artwork. QuickLook's `.icon` of a probe in the app's
caches draws a folder, a bundle, a Mach-O executable and the "?" page a
dangling link, fifo or device gets; `UIDocumentInteractionController.icons`
draws a file type by extension, synchronously. `DeviceIcons.prepare()` blocks
launch (bounded) until the folder and bundle pictures exist, so a synchronous
caller always gets one; a lookup is never nil. The browser page's row icons
are the same pictures, drawn by the app and served at `/_fila/icon-…png`.
`FilePresentation.Icon` has no symbol case. A better picture made from the file itself is one tier in
`FilePresentation.picture`, which rows, the grid and Properties all ask; a
cell's is a square (`SquareImage`) drawn with the thumbnail edge,
Properties' is whole. `Scripts/check-ui-libraries.sh` fails on `systemName` in
the sources that only draw file pictures. Actions, empty states and screen
crumbs keep their symbols: they are controls and labels, not files.

**Servers are managed in Settings › Servers, never in the sidebar.** The
sidebar's Servers section lists saved remote roots as destinations and
nothing else: no *Add …* row, no swipe to edit or remove. The settings page
is built from `BackendConnectionSetup` registrations alone — one group per
module under its `listTitle`, the backends it `owns` with their
`BackendRoot.detail`, one *Add <title>…* row, the module's own screen for
adding and editing, and its `remove`. Nothing in the shell names SMB: an
FTP or SFTP module registers a setup and gets the same page, the same
sidebar rows and the same artwork rule with no shell change.

**A catalogue backend contributes its root row only while it has something to
show**, and every opener — the sidebar, the tab switcher, a `fila://` link —
goes through `registry.screen(for:)` rather than naming a concrete type. The
tab store records a directory per tab, so a catalogue tab restores to the last
directory the user was in; before that it put Music back at `iTunes_Control`.

Each tab retains its full navigation subtree, including preview/editor content
and unsaved work. The tab overview lives in the content area and captures the
actual page. Switching tabs does not close documents; closing or replacing
them goes through the existing save guard. Hide the split view's outer
navigation bars so only the active tab owns visible chrome. Hidden controllers
must not update the visible navigation bar or toolbar on model notifications.

Installed Apps opens in the main content column. Directory hooks decorate the
name, icon and context-menu preview only: keep the real path and FileNode
identity for every operation. Hooked names are brown; query native application
artwork for `.app` icons and container badges. Treat empty native names as
missing. Recents may cache display metadata, but opening one fetches current
file details before choosing its viewer.

Initial listings may stream pages. Refreshes keep current rows, including a
loaded empty state, until the complete replacement is ready; cancel stale
tasks before they publish. Apply one final diff and animate actual removals.
Slow deletion shows its job's delayed `JobCover` card; finish or dismiss only
that operation's own card. Never clear the list just to show loading.
Search scope belongs in its context menu, and search presentation must leave
the native navigation bar stable on entry and exit.

### Localization is verified against the compiler, never against a grep

`Fila/Resources/Localizable.xcstrings` ships English plus twelve translations,
and a key that is missing from it **is not a build failure and never warns** —
it renders the English key itself on a Chinese device, silently. So it has to
be checked, and checked from the right source. Twelve languages also change
what "add a string" costs: a new key is not done when English is written, and
the language that quietly ships English is the one nobody on the team reads.

A release build emits one `.stringsdata` per source file under
`Build/Intermediates.noindex/Fila.build/…/Objects-normal/arm64/`; each is a
JSON (or a plist on older toolchains) whose `tables.Localizable` is an array
of `{key, comment, location}`. Include generated App Shortcuts metadata even
when its `source` is a label rather than a filesystem path.
Those are the exact keys the runtime will look up. Diff that set against the
catalogue and require `missing = 0` and `orphaned = 0`.
`Scripts/check-extracted-strings.py` is that diff and `make build` runs it.

**Skip `GeneratedStringSymbols_Localizable.stringsdata`.** Xcode generates it
*from the catalogue*, not from source, so counting it compares the catalogue
with itself and reports a flawless match no matter how many keys nothing
extracts. It said 706/706, `missing = 0`, `orphaned = 0`, over forty-two keys
that no source produced.

**No catalogue carries `extractionState`.** `manual` means "keep this key even
though I cannot find it", which is how twenty-five orphans accumulated unnoticed
— nothing prunes what Xcode does not own. Without the field, a key that loses
its last call site is marked `stale` on the next build and someone sees it. If a
key needs the marker to survive, that is the call site hiding the literal from
the extractor; fix the call site (see AlertController above), do not annotate
the catalogue. `Scripts/check-localization.sh` fails `make check` on any
`extractionState` in any `.xcstrings`.

**A grep for `String(localized:)` is not a substitute and will lie to you in
two specific ways.** It cannot see SwiftUI's bare `Text("Grid")`, and it cannot
see an interpolated key — `String(localized: "\(count) selected")` is looked up
as `%lld selected`, so the grep sees the interpolation and never the key.
App Intents' `LocalizedStringResource` literals land in the same catalogue and
are invisible to grep for the same reason.

**The extractor walks one target at a time, and the app's `.stringsdata` is
only the app's.** A `String(localized:)` inside `Packages/FilaKit/Sources` never
reaches the app's set, so a diff against that alone reports a clean catalogue
while an entire module ships English — which is exactly what happened to
`FilaTerminal`, ten strings at once, under a check that said 469/469.

So a target that shows the user a sentence owns its own catalogue: the package
declares `defaultLocalization`, the target takes
`resources: [.process("Resources")]`, and the call site names its bundle —
`String(localized: "…", bundle: .module)`. It then emits its own `.stringsdata`
under `FilaKit.build/…/<Target>-t.build/`, and is diffed like any other target
rather than scraped. `FilaFormats`, `FilaMedia`, `FilaTerminal` and
`FilaBackendUI` are set up this way, and the app carries
`CFBundleAllowMixedLocalizations` so it resolves strings out of those resource
bundles.

A **module framework** is a third case, and the intermediates are where it
shows: `FilaApplications`, `FilaMusicLibrary` and `FilaSMB` are compiled by
their Xcode framework targets rather than by SwiftPM, so their `.stringsdata`
lands under `Fila.build/`, not `FilaKit.build/`. `FilaSaveAction` is an
extension with its own catalogue for the same reason. The table in
`Scripts/check-extracted-strings.py` names all nine checked targets and where
each one's intermediates live. Add a new target to that table when it grows
its first string; a target missing from it is not checked at all.

`String(localized:)` defaults to `Bundle.main`, which is why the FilaTerminal
strings *worked* while sitting in the app catalogue and were still wrong: the
lookup found them, and the extractor never put them there, so the first prune
would have taken all ten.

Two rules the catalogue enforces on itself: a translation keeps every format
specifier with the same type and count, and uses positional forms (`%1$@`,
`%2$lld`) wherever the target language reorders them — getting that wrong is a
crash at format time, not a wording problem. And the blunt warnings stay blunt
in every language: the guard refusal, the replace-is-not-undoable line, the
interrupted-transfer line and the archive refusals are deliberately alarming,
and softening one in translation means only that language's users lose a file.

### Working in parallel: the risk is at the merge, not in the branch

Keep a terminal leader waitable until delayed process-group signals finish,
so PID reuse cannot retarget cleanup. A retry deadline is not evidence of
reaping, and signaling the original group does not cover a whole session.

Ten agents were merged into `main` in one night. Every one of them had run
`/code-review` on its own diff; every bug that reached `main` came from the
*resolution*, not from the branches. If work is being split again, expect
these and check for them by name:

- **Two agents fixing the same bug produce a double-fix.** Two independently
  correct patches for "a job whose link dropped hangs forever" merged into a
  `CheckedContinuation` resumed **twice**, which is a crash rather than a
  duplicate notification. Any callback that resumes a continuation must be
  taken off its row before anything else runs and called exactly once.
- **Identifiers collide silently.** Two agents both took `FilaOperation = 16`;
  three took the same pbxproj object IDs. Git merges those without complaint
  and produces a project referencing the wrong product, or two sides calling
  different operations while each believes it is calling the other's. After any
  multi-branch merge, verify raw values are unique and every `productRef`
  points at the product its comment names — `make check` does not.
- **DerivedData is shared.** `DERIVED_DATA` defaults to one path, so concurrent
  builds cross-contaminate and hand out false greens and false reds. Give every
  parallel worker its own (`make build DERIVED_DATA=/tmp/fila-dd-<name>`).
- **Worktrees are cut from an older base.** Verify the intended base before
  creating an isolated checkout, and pin it in the brief. Never reset a shared
  working tree containing another contributor's changes.
- **A file nobody owns gets edited by nobody.** Six agents were each told to
  keep out of the string catalogue so they would not fight over one JSON blob.
  That worked, and left a hundred keys missing because no one was assigned to
  collect them. Whatever is excluded from every worker needs an owner at the
  end.

## Naming

Bundle identifiers are lowercase throughout: app `wiki.qaq.fila`, daemon
`wiki.qaq.filad`, Mach service `wiki.qaq.fila.service`, client entitlement
`wiki.qaq.fila.client`, Debian package `wiki.qaq.fila`. Installed at
`@PREFIX@/Applications/Fila.app`, `@PREFIX@/usr/libexec/filad`,
`@PREFIX@/Library/LaunchDaemons/wiki.qaq.filad.plist`.

Localization is English plus twelve translations: Arabic, German, Spanish,
French, Italian, Japanese, Korean, Brazilian Portuguese, Russian, Vietnamese,
Simplified Chinese and Traditional Chinese. Every catalogue in the repository
ships all thirteen. Nothing in `make check` verifies that a key is translated
into all of them — the checks prove that a key exists and that it came from
real source, not that anyone wrote the Korean. So a string that has only
English passes every gate and ships English in twelve languages; completing
a new key is part of adding it, not a later pass.

## RootHide runtime dependency policy

Evaluate official `libroothide`/`libvroot` before adding a new bootstrap path
shim. This native app/daemon currently keeps a physical-path contract: process
identity, filesystem decisions and Foundation must refer to the same path.
Do not apply `symredirect` to only one side of that boundary. Packaging rejects
an accidental vroot dependency on the native daemon. Both package layouts may
reuse these native binaries; `libvroot` itself is RootHide-specific and is not
made rootless-compatible by changing the Debian architecture label.
References: `roothide/Developer`'s `vroot.md`, and `roothide/libroothide`'s
`init.c` and `stub.h`. `libroot` is a separate Rootless v2 path API.
