# Fila — Agent Notes

Root file manager for jailbroken iOS 15+ — roothide and rootless bootstraps
both. **iOS only**: there is no Mac Catalyst build and no macOS product. The
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
- **The daemon writes wherever root can; only the File Provider is fenced.**
  `FileOperations.writableRoot` confines a backend that serves one folder —
  the File Provider extension — and nothing else sets it. A root file manager
  confined to its own bootstrap is not one: `/var/mobile` is outside every
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
  and opens nothing. A read-only volume or a cross-volume rename fails with
  the real errno, and the app offers a permanent delete instead of pretending
  the trash always works.
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
  parse tables, shown to the user, chosen), swift-nio (the WebDAV framer),
  SnapKit (layout), Then (view setup), AlertController (the one alert card),
  and SPIndicator (the toast chrome under `Toast`). **No third-party
  dependency links into `filad`.** The next library needs the same argument:
  what it replaces, and why the hand-written version would be worse rather
  than merely longer.

## Layout

- `Fila/` — the app. `main.swift` (manual `UIApplicationMain`) + `Application/`
  (delegates) + `Interface/<feature>/` + `Resources/`. UIKit is the shell and
  the file list will stay a collection view; SwiftUI is used inside individual
  screens.
  App source is organized by ownership:
  - `Application/State/` — `AppPreferences`, `FileClipboard`, `BrowserTabStore`
    and shared app-list options; `System/` owns capability availability.
  - `Services/Files/` — `FileSession`, `DirectoryReader`, `FileSearch` and
    blocking `DescriptorIO`; `Transfers/` owns `OperationCenter` and downloads;
    `Sharing/` owns `FileSharingServer` and `WebDAVFileService`; `Applications/`
    and `Installation/` own installed-app discovery and IPA installation.
  - `Interface/` groups screens and views by feature. `Navigation/` owns the
    shell and links; `Applications/` owns app details; `FileActions/` owns
    shared action/destination panels; `Feedback/` owns errors and toasts;
    `Shared/` holds reusable UI including `FilaUI` and `FilePresentation`.
  `FileSession.operations` directly owns the single `OperationCenter`; do not
  restore the removed `JobCenter` forwarding layer or its failure mailbox.
  Keep filenames aligned with their owning type; independently navigable
  extensions use `Type+Concern.swift`. Keep wire values, UserDefaults keys and
  Codable fields stable when renaming Swift symbols.
- `Filad/` — the daemon, product `filad`. `main.swift` + `Server/`
  (`DaemonServer` listener, `PeerAuthenticator`) + `System/` (`InstallRoot`,
  the libSystem shims).
- `Packages/FilaKit/` — the local Swift package containing the core modules
  and the terminal's conditionally compiled UIKit views. The daemon links
  **only** `FilaProtocol` (the wire vocabulary and
  `FilaGuard`), `FilaFileOps` (the root side's POSIX calls and jobs) and
  `FilaLog` — that list is a budget, not a habit, and everything else in the
  package is app-side because launchd caps the daemon at 6 MB. The app also
  links `FilaClient` (the XPC link *and* the in-process backend behind one
  `FileService`), `FilaFormats` (readers and writers that allocate by content
  size, over a descriptor the daemon handed back; libarchive lives here),
  `FilaMedia` (AVFoundation and ImageIO over the same descriptors),
  `FilaTerminal` (the pty pump and libghostty) and `FilaRemote` (the WebDAV
  server and URL download). The package's libarchive, libghostty and NIO
  dependencies are app-side; Runestone, AlertController and SPIndicator belong
  to the app target. SnapKit and Then may be imported by `FilaTerminal` — it is
  UIKit, and it is not the daemon — and by nothing the daemon links. It used to be
  `Shared/`; the reason it moved is that the code that can destroy the user's
  filesystem — the actual `copyfile`/`removefile` jobs, not just the guard —
  could not be tested without building the daemon, and now it can: each
  product has its own `swift test` target under `Packages/FilaKit/Tests/`.
  Core code must build and test on macOS with plain SwiftPM, without building
  the iOS app or daemon. UIKit-only code stays behind `canImport(UIKit)`;
  the host harness does not create a macOS product.
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
- `Documentation/Architecture.md` for the design in full,
  `Documentation/Roadmap.md` for what was deliberately deferred and why.

There is deliberately **no CLI target**: the app is the only client. Its XPC
link to `filad`, `DaemonLink`, lives in `FilaClient` rather than beside its
callers in the app, so the backend can be tested through the same host harness.

## App UI libraries

Fila is UIKit. iGhostVT is SwiftUI, so it redrew Lakr233/AlertController as
`AlertCardView`; Fila uses the package itself. The four libraries below are
the only way their jobs get done. `make check` greps the app target and
`FilaTerminal` for the APIs they replace, and fails the build when one
comes back.

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
`translatesAutoresizingMaskIntoConstraints = false` do not appear in
`Fila/` or `FilaTerminal`. SnapKit turns the mask off itself.

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
`String.LocalizationValue`. Pass the literal so Xcode extracts the key.
The package also has a `String` overload marked `@_disfavoredOverload`:
a `String(localized:)` argument, or any already-resolved string, becomes
the lookup key and ships English on a Chinese device. Computed copy
(`FailureMessage.text(for:)`, a path) is the `String` overload on
purpose — it is not a catalogue key.

The package has `.normal` and `.accent`, not `.destructive`. Permanent
file deletion uses `PermanentDeleteConfirmation`, which constructs the standard
package alert under a temporary system-red accent and restores the default.
Every alert has a visible Close/Cancel/OK action;
`context.allowSimpleDispose()` only enables Escape and does not add a button.
Deletion icons use the standard `trash` symbol, never `trash.slash`.

One line of input is `AlertInputViewController` (rename, new folder, jump
to offset). Do not revive `addTextField` to set `keyboardType`. Delayed
work that currently presents a system progress alert is
`AlertProgressIndicatorViewController`; update the message with
`progressContext.purpose(message:)`, and keep FileActions' delayed
reveal — a job that finishes in a blink never shows the card. Dismiss
only that operation's own alert.

A card does not need a popover source. `anchor(_:to:)` remains for
share sheets and document pickers, not for alerts.

### SPIndicator — only through `Toast`

Transient "copied / undone / finished" feedback is `Toast.show`. Do not
construct `SPIndicatorView` at a feature call site, and do not present
an alert for something that has no question and no button. Errors that
need a title, a reason and Close stay AlertController; `FeedbackAlert` finds
the active presenter when the original screen is gone. `Toast` is success-only:
a single line with SPIndicator's `.done` preset, without custom icons or subtitles.
Its optional Undo action remains available on that same line.

`Fila/Interface/Feedback/Toast.swift` is the only file that imports
SPIndicator. It already queues, hosts a passthrough window, and wires
the one action (Undo) onto the indicator. Extend that wrapper if the
chrome is wrong; do not fork a second presenter.

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

- `make harness` — `swift test --package-path Packages/FilaKit`. No device, no
  simulator. Run this before anything else; it is where a guard mistake, or a
  copy that loses an xattr, gets caught.
- `make check` — project and packaging validation, including the UI-library
  grep (no `UIAlertController`, no `NSLayoutConstraint.activate`, no
  SnapKit-bypass `translatesAutoresizingMaskIntoConstraints`, no
  `SPIndicatorView` outside `Toast.swift`).
- `make build` — unsigned `Fila.app` + `filad` for iPhoneOS (runs `check` and
  `harness` first).
- `make sim` — Debug build onto the booted simulator. There is **no daemon**
  there and there cannot be: `launchd_sim` prefixes every job's program path
  with the runtime root, which is a sealed read-only volume, so no launchd job
  can ever point at our binary and the Mach service is never registered.

  The simulator is nevertheless a real test surface, because the app falls back
  to the in-process backend after the grace period and then browses the Mac's
  own filesystem — listing, viewers, properties, search, the whole shell. What
  it does **not** exercise is anything privileged: the XPC hop, the
  authenticator, the daemon's guard, a descriptor opened as root. Use it for
  everything visual and then prove the privileged half on the vphone.

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
  `Scripts/verify-ipa.sh`. The `.tipa` is ad-hoc signed with the same
  `Packaging/Fila.entitlements` as the deb (TrollStore applies what it finds
  embedded); the `.ipa` carries **only the configured standard App Group**
  entitlement. The user approved this shared-container workflow: the sideloading
  tool must provision the same `APP_GROUP_IDENTIFIER` for the app and embedded
  File Provider when re-signing. Jailbreak/private entitlements stay excluded
  from the ordinary IPA and from the File Provider extension.
  Path helpers: `make print-tipa-path`, `make print-ipa-path`.
- `make packages` (`make all`) — all four in one go.
- **One app, four wrappers — and the backend is resolved at runtime, never at
  build time.** Never add a build flag, a compilation condition, or a
  per-packaging source variant to tell the four apart.

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
  on the containing app and its embedded File Provider.

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
directories. Derive the location from `Hello.backend`: the
daemon uses `<installRoot>/.fila-tmp/<process UUID>`; the local backend uses
the app's system temporary directory under `wiki.qaq.fila/<process UUID>`.
Never hardcode a bootstrap prefix or use its `tmp` symlink, which may lead
outside the writable root. The daemon's fixed parent stays root-owned 0755
and contains only UUID directories; actual content stays in mobile-owned
0700 workspaces. Verify an existing parent's type, owner, permissions and
canonical path rather than changing an unknown directory's ownership.

Each consumer removes its own UUID directory when finished, including share
cancellation and failed preview handoff. Startup lists the dedicated parent
before deleting stale UUID directories and waits for each delete job's result.
Normal exit makes a synchronous best effort to empty the privileged workspace;
its empty UUID directory is removed at the next startup. Local exit removes
the whole workspace. SIGKILL cannot run cleanup: the next startup removes its
leftovers. Do not turn an accepted cleanup job into a claimed completion.

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

Every pushed screen must have all of its bar button items ready before the
UIKit push starts. Build screen-owned items in initialization, and prepare
Back/Places from the destination stack in `TabNavigationController`. Viewers
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
Slow deletion can show the delayed `AlertProgressIndicatorViewController`;
finish or dismiss only that operation's own alert. Never clear the list just to show loading.
Search scope belongs in its context menu, and search presentation must leave
the native navigation bar stable on entry and exit.

### Localization is verified against the compiler, never against a grep

`Fila/Resources/Localizable.xcstrings` ships English and Simplified Chinese,
and a key that is missing from it **is not a build failure and never warns** —
it renders the English key itself on a Chinese device, silently. So it has to
be checked, and checked from the right source.

A release build emits one `.stringsdata` per source file under
`Build/Intermediates.noindex/Fila.build/…/Objects-normal/arm64/`; each is a
JSON (or a plist on older toolchains) whose `tables.Localizable` is an array
of `{key, comment, location}`. Include generated App Shortcuts metadata even
when its `source` is a label rather than a filesystem path.
Those are the exact keys the runtime will look up. Diff that set against the
catalogue and require `missing = 0` and `orphaned = 0`.

**A grep for `String(localized:)` is not a substitute and will lie to you in
two specific ways.** It cannot see SwiftUI's bare `Text("Grid")`, and it cannot
see an interpolated key — `String(localized: "\(count) selected")` is looked up
as `%lld selected`, so the grep sees the interpolation and never the key.
App Intents' `LocalizedStringResource` literals land in the same catalogue and
are invisible to grep for the same reason.

**And the `.stringsdata` set has a blind spot of its own: Xcode's extractor
only walks the app target.** A `String(localized:)` inside
`Packages/FilaKit/Sources` never reaches a `.stringsdata`, so a diff against
that set alone reports a clean catalogue while an entire module ships English —
which is exactly what happened to `FilaTerminal`, ten strings at once, under a
check that said 469/469. Package-target strings have to be scraped instead,
which is the weaker method and inherits the interpolation hole above: keep
strings in package targets plain, with no interpolated keys, so that a scrape
can see all of them.

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

Localization is English and Simplified Chinese.

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
