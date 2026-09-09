# Roadmap

What exists, what comes next, and what was deliberately left out. Nothing here
is a promise — it is a record of decisions so they don't get re-argued.

## Now

The whole vertical slice runs on a device. `filad` serves every operation in
`FilaOperation`; the app browses, edits, copies, moves, deletes to the trash,
compresses, and opens what it finds in a viewer. `make packages` builds four
outputs — the roothide and rootless `.deb`, a TrollStore `.tipa`, and a
sandboxed `.ipa` — and `make install` puts one on a device over `iproxy`.

The part worth stating plainly, because it is what the package split bought:
the code that can destroy the user's filesystem is reachable from `swift test`
on a Mac, and that is where the two worst bugs so far were caught — a guard
that would have let `/var` be unlinked because the leaf symlink was never put
through it a second time, and a `copyfile` callback that answered
`COPYFILE_CONTINUE` on an error stage, so a partly-failed cross-volume move
deleted originals that had never copied.

Shipped with that slice, and no longer future work:

- `FileService` with two backends, chosen at handshake: XPC to `filad`, or
  `FilaFileOps` in-process for the `.tipa`, the `.ipa`, and the simulator.
- libarchive, statically linked, for the formats Fila reads and writes. 7z
  and RAR stay read-only.
- Runestone for the text editor.
- Tabs with a retained navigation stack each, and one `OperationCenter` for
  jobs, transfers and toasts.
- WebDAV server and the bundled browser UI in `WebUI/`.
- Files.app integration through the embedded File Provider (iOS 16+).

A version tag runs `.github/workflows/release.yml` and publishes the four
packages. Local `make check`, `make harness` and `make packages` remain the
gate a change has to pass before it is called done.

## Next

1. Content search: matching inside files, not only names. The walk already
   exists; what it needs is a bounded reader and a decision about binary files.
2. Re-query the daemon after the in-process fallback and rebind when it
   answers. Running jobs must move with it. See the note on
   `DaemonLink.graceBeforeFallback`.
3. Verify single-process mode on a real LiveContainer host: icon getter,
   `LSApplicationWorkspace` timing, and that no listed path hangs in
   `opendir`. A sandboxed Applications page could show this app's own
   container instead of hiding, if that is ever worth a row.

## Deferred, on purpose

Recorded because they were asked about and answered "not now", not because they
are bad ideas.

Filza's "Scripts" feature — running a shell script from the file list — is
**planned, and deliberately not now**. It is worth writing down what makes it
hard, so that whoever picks it up starts from the real problem rather than
rediscovering it:

Running a script is easy. Running a *useful* one wants root, and root here
means `filad` — and "a root daemon that accepts a command" is precisely the
thing the audit-token check, the executable-path check and the whole trust
boundary exist to prevent. Whoever designs this has to answer that, not route
around it. The shapes worth weighing when the time comes:

- run it as `mobile` from inside the app, which is safe and honest and cannot
  do most of what someone wants a script for;
- spawn a separate helper for it, the way `ighostvtd` spawns its child, so the
  daemon still executes nothing itself and the executing process is a distinct,
  auditable program with its own narrow contract;
- accept root execution behind an explicit per-run confirmation that names the
  script and cannot be driven by the app silently — the honest version of what
  Filza does, and the one that needs the most care.

Nothing about this is decided. What *is* decided is that it does not arrive as
"add an exec operation to `FilaOperation`".

| Feature | Note |
| --- | --- |
| SMB / FTP clients and extensible backends | [Architecture](RemoteClients.md) and [phased implementation plan](../PLAN.md): MIT SMBClient/libcurl, shared subscriptions, backend-owned roots/DefaultStorage, merged sidebar and cross-backend copy/move. Not implemented. |
| ApplicationBackend / MusicLibraryBackend extraction | [Named backend and controller plan](RemoteClients.md#backend-and-controller-class-plan): shared sidebar/preferences/list lifecycle, domain-specific typed actions. Not implemented. |
| Bundled backend module discovery | [Confirmed startup design](RemoteClients.md#bundled-frameworks-and-automatic-startup-discovery): Local/Privileged/SMB/FTP/Applications/Music frameworks, shared BackendKit/BackendUI, startup Mach-O linking and manifest/name-based discovery. Exact app version/build; bootstrap failures logged and omitted from UI. Not implemented. |
| Sandboxed IPA / potential App Store composition | Proposed FilaSandboxed target with app/music modules excluded from its binary; [root and subclass design](RemoteClients.md#backend-roots-and-sandboxed-local-specialization). Dependency isolation and distribution audit remain future work; no approval claimed. |
| SFTP / WebDAV clients | Deferred. The device is already a WebDAV *server*; outbound clients are separate. SFTP authentication belongs to connection setup behind the proposed shared contract. |
| Markdown preview | Asked for and declined. |
| SQLite browser | A viewer, but much larger than the others, and the only one that wants a real database engine rather than a parser. |
| Passcode / Face ID lock | Reasonable for an app that can read the whole filesystem. It is a feature rather than a setting. |
| A rootful `.deb` | Only roothide and rootless are built. The daemon resolves its own prefix, so rootful is close to free if wanted. |
| A Mac product | Removed. Fila is iOS only; the Mac is a test host for `FilaKit`. |
| A full audio/video editor | Playback and Now Playing are shipped. Trimming and waveform editing were evaluated and declined — see `Audio-Playback.md`. |

## IPA installation

Asked for as "install an `.ipa` from Fila" — first via
`LSApplicationWorkspace installApplication:`, then, when that turned out to be
stubbed, via InstallCoordination, with the appinst/TrollStore source as the
reference. Verified on the vphone (iOS 26.6.1, Dopamine-style rootless
`/var/jb`, TrollStore Lite present, **no AppSync**) on 2026-09-05.

**Two APIs, one per era; both reach the same wall.** Fila runs on iOS 15+, so
the install path is a runtime chain, never a build flag:

- **iOS 15** — `-[LSApplicationWorkspace installApplication:withOptions:error:]`
  is live (the classic appinst/AppSync route). *Source/symbols only; not run
  on iOS 15 in this tree.*
- **iOS 16+** — that selector is a stub: it returns `NSOSStatusErrorDomain -4`
  before touching the package, and the CoreServices binary says why in as many
  words — *"this process is using %s to install applications, which is not
  supported. Use InstallCoordination to install and uninstall applications on
  this platform."* (`MobileInstallationInstallForLaunchServices` is gone from
  `MobileInstallation.framework` too.) The live path is
  `+[IXAppInstallCoordinator installApplication:consumeSource:options:completion:]`
  with an `MIInstallOptions` (built from the legacy `{PackageType: …}` dict),
  talking to installcoordinationd. *The class and selector are present in the
  17.3.1, 18.5 and 26.6.1 DeviceSupport symbols; **run on 26.6.1**.*

`IPAInstaller.install` tries the coordinator first and falls back to the
workspace, so one code path covers every supported OS.

**What the vphone run established (iOS 26.6.1), in the order a request meets
it:**

1. **installcoordinationd refuses unentitled clients.** Its own log string:
   *"Process … is missing `com.apple.private.InstallCoordination.allowed`
   entitlement so rejecting connection attempt."* Without it the call fails
   `IXErrorDomain 1 "Failed to create temporary staging directory"` (underlying
   `NSCocoaError 4097`, the refused connection). That is what Fila got until
   the deb gained the entitlement; it is honoured when fake-signed with `ldid`
   on this jailbreak, so `Packaging/Fila.entitlements` now carries it. It lets
   Fila *talk* to the installer — nothing more. **Uninstall is gated by a
   second one, `com.apple.private.InstallCoordination.uninstall`**: without it
   the daemon answers `IXErrorDomain 25 "Client … is missing entitlement
   com.apple.private.InstallCoordination.uninstall … to uninstall
   applications"`, and a refused install's placeholder cannot be cleaned up.
   The deb carries that too.
2. **installd then checks the signature itself**, and refuses an unsigned,
   ad-hoc, or `jb.pmap_cs.custom_trust`-signed bundle with
   `MIInstallerErrorDomain Code=13`, `0xe800801c (No code signature found)` —
   `custom_trust` is honoured by AMFI at exec, not by installd's
   `MICodeSigningVerifier` at staging. A genuinely Apple-signed IPA advances
   exactly one step, to `0xe8008015 (no valid provisioning profile for this
   device)`. This trust check is precisely what **AppSync Unified** removes
   (it hooks `MISValidateSignatureAndCopyInfoWithProgress` inside installd),
   and there is none on this device.
3. **A refused install leaves a placeholder** — installd registers the app
   before fulfilling it — so a failed attempt must be followed by
   `+[IXAppInstallCoordinator uninstallAppWithBundleID:error:]`, which works
   (it removed every placeholder and test app cleanly). The coordinator's
   lookup and uninstall halves are therefore usable today; only the install
   half is gated on trust.

**Verdict.** InstallCoordination is the correct, supported transport on iOS
16+ and Fila can now reach it; **installing an arbitrary IPA stays blocked on
a stock jailbreak without AppSync Unified or a trustcache**. The one route
that does install here is TrollStore Lite's helper (ldid `custom_trust`
fake-sign, `MCMAppContainer`, `registerApplicationDictionary:` — a signing and
container-registration pipeline that bypasses installd, already on the
device), so handing an `.ipa` to TrollStore remains the honest user-facing
shape until AppSync is a stated requirement. None of this belongs in `filad`:
`installd` does the work as `_installd` whichever process asks, and root buys
nothing.

**Current implementation:** `Fila/Services/Installation/IPAInstaller.swift` owns
installation through the IX → LS chain. Runtime probes and installation
fixtures were removed in 0.1.6; build-time tests remain in `Packages/FilaKit/Tests`.

## Done, and where the decision is written down

| Was deferred | Now | Where |
| --- | --- | --- |
| Whole-device search | A daemon job that walks with an explicit `opendir` stack and never `stat`s an entry it is not going to return. The earlier note here said a daemon-side walk would allocate inside the 6 MB budget; that was true of `fts(3)` and not of the walk that was written. | `Architecture.md` |
| Archives | libarchive over descriptors. ZIP, TAR and the compressed TAR filters are writable; 7z and RAR are read-only. | `FilaFormats` |
| Mach-O and entitlement viewer | Built, including the entitlements plist out of the code-signature superblob. | `Fila/Interface/Viewer/` |
| App container jump | App-side through `LSApplicationWorkspace`. The documented limit is that nothing on disk links a bundle UUID to its data UUID, so the fallback scan finds bundles only. | `Fila/Services/Applications/InstalledAppCatalog.swift` |
| Bookmarks, tabs, recents | App-side state. Each tab retains its navigation stack. | `Fila/Application/State/` |
| TrollStore / sideloaded packages | `make tipa` and `make ipa`, app only, no daemon — the in-process backend after the grace period. | `Scripts/package-ipa.sh` |
| FileService | Two backends, one handshake. Never a build flag. | `Architecture.md` |
| Text editor | Runestone, same atomic-save path. | `Fila/Interface/Viewer/` |
| Built-in web server | WebDAV plus `WebUI/`. | `FilaRemote`, `WebUI/` |
| Files.app integration | Replicated File Provider, iOS 16+, no daemon, no root. | `FilaFileProvider/README.md` |
