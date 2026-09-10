# Architecture

## Why there is a daemon at all

SpringBoard launches every app as `mobile`. No entitlement changes that, so an
app cannot read `/private/var/root` or write `/System` no matter how it is
signed. Root access on a jailbroken device means a separate root process, and
the only sane channel to one is XPC — which carries an audit token the kernel
fills in, so the daemon can decide who is asking without trusting anything the
caller said.

That gives the process model:

```
Fila.app (mobile, unsandboxed)          filad (root, on-demand LaunchDaemon)
  DaemonLink        ──── XPC ────────►  DaemonServer
                                          PeerAuthenticator  (audit token)
                                          FilaGuard          (what may be destroyed)
  read()/write() ◄──── fd ──────────────  open(2)
```

`filad` is an on-demand daemon: looking the Mach service up starts it, and it
exits three seconds after the last client disconnects. An idle device carries
no process for Fila — with one exception, added deliberately: it will not idle
out while a terminal it spawned is still unreaped, because a shell reparented
to launchd is exactly what "nothing outlives the app that asked for it" is
meant to prevent.

When the daemon is absent, `FileSession.ready()` retries the Mach lookup
once a second, forever — on a jailbroken device a miss means launchd has not
spawned `filad` yet. A build that shipped no daemon settles instead on the
in-process backend; see *Single-process mode* below.

## The descriptor rule

launchd sizes a daemon at 6 MB on the device. A file manager moves gigabytes.
Those two facts cannot both be satisfied by a daemon that carries file
contents, so it doesn't: `FilaOperation.openPath` opens the file as root and
returns the descriptor over XPC. The app then reads and writes it directly.

Consequences worth stating explicitly, because they are easy to erode later:

- There is no `readFile` / `writeFile` operation, and adding one would undo the
  design. A request that wants bytes wants a descriptor.
- The daemon's memory is flat and does not depend on what the user is doing.
  This is what removes the need for the two-process split `ighostvtd` uses.
- The kernel checks permission at `open`, once, against the daemon's root
  credentials. A descriptor already opened stays usable — which is what makes
  the design fast, and also why the daemon must decide carefully *before* it
  opens anything.

Directory listings are the exception that proves the rule: a directory
descriptor would not help, because `openat` on an entry re-checks permissions
against the *caller's* uid, and the caller is `mobile`. So listings are
metadata the daemon produces itself — `readdir` plus `fstatat`, paged at
`FilaProtocol.directoryPageEntryCount` entries with a cursor. A directory with
100k entries must never become one message, and must never become one array
inside the daemon either.

## Where heavy work runs

There is no worker process, and that is a decision, not an omission.
`ighostvtd` splits into a proxy and a child because PTY replay buffers grow
*inside* the daemon — bytes pass through it. Fila's don't: `openPath` hands out
a descriptor and the daemon is done with those bytes. So everything that
allocates by content size — archive extraction, Mach-O parsing, property
lists, hex, thumbnails, media playback — runs in the app, which has gigabytes
to spend, over descriptors the daemon opened as root. What stays in the daemon
is only what needs root *and* stays flat in memory: `open`, `stat`, one page of
`readdir`, `rename`, and the `copyfile`/`removefile` jobs below.

**Whole-device search is one of those.** It used to be app-driven over paged
listings, on the reasoning that no walk may allocate inside a 6 MB daemon —
which was true of `fts(3)` and not true of the explicit `opendir` stack that
was actually written. A depth-bounded stack of open directory handles is flat:
its cost is the depth, not the tree. So the walk runs in `filad`, where it
does not pay an XPC round trip per directory, and streams matches back in
batches. 460k entries in about 2.6 seconds on the development device.

The terminal keeps the same descriptor boundary. `openTerminal` opens a PTY
and uses ordinary `posix_spawn` to start `filad --terminal-session`. This
internal mode runs before XPC and logging initialize. It establishes the
controlling terminal, drops credentials for mobile, enters the working
directory with those credentials, and uses ordinary `posix_spawn` to start
the account shell or fixed program. Fila uses neither fork/exec calls nor
`POSIX_SPAWN_SETEXEC`.

The session holder waits for the program and cleans its original process group
before reaping its leader. The daemon retains only the holder PID and a dispatch
source; the app owns the PTY master and reads its bytes directly. The holder does
not proxy output and is another invocation of the installed daemon, not a new
package executable. The XPC request still cannot supply argv or an environment.

Root launches use device-owner authentication in the app when the device has a
passcode. Cancellation prevents the launch request. This UI check supplements
the daemon's peer authentication; it does not authenticate arbitrary XPC callers.
Account startup files remain intentional. Mutable programs run as root take the
direct spawn path rather than waiting through login startup before execution.
The audit record distinguishes the selected canonical target from its launcher;
starting the launcher does not imply that startup files reached the target.

## The trust boundary

`PeerAuthenticator` runs before any request field is read. On iOS it requires,
from the kernel audit token:

- a real pid, and an effective uid of `root` or `mobile`;
- the entitlements `wiki.qaq.fila.client`, `platform-application` and
  `com.apple.private.security.no-sandbox` — a sandboxed App Store app cannot
  obtain these, and the first is ours alone;
- an executable path equal to the installed app, resolved through `realpath`
  and required to be a root-owned regular file that is not group- or
  world-writable. Admitting by path is only safe if nobody unprivileged could
  have replaced what is at that path.

There is no Mac product and no Catalyst daemon, so there is no second
admission path. The Mac is only the host for `make harness`.

## The guard

`FilaGuard` is the difference between a file manager and a brick generator. Its
rule is deliberately narrow:

> A protected node may not itself be deleted, moved away, or replaced.
> Everything inside it stays editable.

Refusing whole subtrees would make the app useless — editing files under
`/System` and `/var/mobile` is why it exists. Refusing nothing makes one
mistyped gesture unrecoverable. The list covers the volume root, the classic
system directories, the container roots, and — resolved at runtime, never
hardcoded — the jailbreak bootstrap root, whose loss takes the jailbreak and
Fila with it.

Two properties matter more than the list:

1. **It is enforced in the daemon.** The client may grey out a menu item as a
   courtesy. It is not a security control and must never be treated as one.
2. **It compares canonical paths.** `/var` is a symlink to `/private/var`. A
   guard entry for `/private/var/mobile` that could be spelled
   `/var/mobile/../mobile` and slip through is not a guard. `realpath(3)`
   first; `FilaGuard.normalize` collapses `.`, `..` and duplicate separators as
   a second line.

The escape hatch — the "I know what I'm doing" switch — travels as
`FilaWireKey.overrideGuard` on the request and is honoured by the daemon for
every protected node **except the volume root and the bootstrap root**, because
those two have no recovery path on a phone. That exception is a decision, not a
technical limit; it can be revisited.

## Long-running work

Copy, cross-volume move and delete are jobs, not replies: they take minutes,
need progress, and must be cancellable. They run inside the daemon on
`copyfile(3)` and `removefile(3)`, whose state callbacks provide progress and a
`QUIT` return for cancellation, and whose memory is bounded regardless of tree
size. A same-volume copy attempts `clonefile(2)` first — on APFS it completes
instantly and consumes no space until one side is written.

Using libSystem here rather than a hand-written walk is not laziness for its
own sake: `copyfile` preserves extended attributes, ACLs, resource forks, BSD
flags and sparseness. Every one of those is something a hand-written copy loses
silently, and a file manager that silently changes files is worse than one that
refuses to copy them.

Same-volume move and trash use an exclusive rename. A relocated daemon keeps
its trash at `<install root>/.fila-trash`; other backends use the source volume.
When those locations are on different volumes, the job publishes a complete
`copyfile` copy before removing the source. The trash copy carries the canonical
origin in `wiki.qaq.fila.origin` before source removal, so even a failed or
cancelled removal leaves a recoverable copy. Put Back runs the same cross-volume
move as a daemon job, refusing occupied origins. Undo matches origin and
`wiki.qaq.fila.trash-job`, a batch UUID that survives copying, rather than inode.
A read-only trash fails with the real errno and the app offers permanent deletion.

## Atomic writes

An editor saves by writing a temp file in the same directory, copying the
original's mode, owner, times, extended attributes and BSD flags onto it, and
`rename(2)`ing it into place. Power loss cannot leave half a file, which for a
system plist is the difference between a reboot and a restore.

The cost is real and is accepted knowingly: `rename` replaces the inode, so
hard links to the old file keep the old content, and a process holding the file
open never sees the new bytes. Fila takes that trade because the alternative —
`O_TRUNC` over the original — can destroy a file the user has no copy of.

## Host testing, not a Mac product

Fila is iOS only. There is no Mac Catalyst build and no macOS app. The file
layer lives in a Swift package so `make harness` can run it on a Mac against a
real filesystem — that is a test host, not a product. The macOS paths in
`FilaGuard` (`/Users`, `/Volumes`, and the rest) exist because those tests
run on a Mac and must not be able to delete the host's own roots.

## Single-process mode

The XPC daemon is the jailbreak architecture. The same binary also has to run
where there is no daemon and never will be: the TrollStore `.tipa`, the
sideloaded `.ipa`, the simulator, and a copy hosted inside a LiveContainer-style
app — an app running inside *another* app's sandbox. That last environment
looks like this:

- the process is `mobile`, sandboxed with the host app's profile; the writable
  root is the host's container, and `NSHomeDirectory()` is somewhere inside it;
- no Mach service: `wiki.qaq.fila.service` is unregistered *and* denied by the
  sandbox, and both look identical to XPC (`XPC_ERROR_CONNECTION_INVALID`);
- no `posix_spawn`, no `forkpty`, no root — nothing can be run;
- private frameworks load, but their answers are the sandbox's:
  `LSApplicationWorkspace` returns little or nothing,
  `/var/containers/Bundle/Application` is `EACCES`, SpringBoard icon getters
  may return nil. None of that may be allowed to hang or crash the shell.

**How it maps onto what exists.** There is no fifth wrapper and no build flag:
`DaemonLink.hello()` asks for the daemon, and a build with no `filad` beside
its bundle falls back to `LocalFileService` once the grace period has run out.
The grace period is `DaemonLink.graceBeforeFallback`, 2.5 s, measured from the
first missed lookup. Once that duration has elapsed, the next handshake attempt
may select the local backend; polling and scheduling can add to the visible
*Connecting…* time. A daemon shipped beside the bundle
never falls back, which is what keeps a slow respring from demoting a root
file manager. `Hello.backend` then carries the answer: `.daemon(installRoot:)`
or `.local(reach:)`.

`FilaFileOps` is an explicitly static Swift package product shared by the
daemon and `LocalFileService`. The local backend invokes that same syscall
implementation inside the app process; it does not spawn a helper or receive
root privileges. The daemon retains its descriptor-only XPC boundary.

**Sandboxed local versus unsandboxed local** is already detected, in
`LocalFileService.probeReach`: `opendir` on the parent of the app's own
container. The sandbox never grants that directory and the app's own user owns
it, so the answer is exactly the claim about to be made to the user — with no
private API and no hardcoded path. `sandbox_check` would answer the same
question through a private symbol; `access("/var/mobile", R_OK)` would not,
because a sandboxed process can often stat a directory it cannot list. The
result is `Reach.container` (sandboxed: the `.ipa`, a LiveContainer host) or
`Reach.user` (unsandboxed: the `.tipa`). The simulator is pinned to
`Reach.container` by `LocalFileService.processReach`: its process is not
sandboxed, but no wrapper of this app runs in that shape, and the `.ipa` is
what it stands in for. `FilaLocalModule` builds the sandboxed backend on
container reach before it looks for a privileged provider, so both
compositions behave alike there.

The main content waits for that handshake before constructing its first
`BrowserTabStore`. A container backend defaults to `NSHomeDirectory()` and
offers that directory as *Home* in Places, instead of Root and Mobile.
Restored Root/Mobile tabs migrate to Home. History for paths under Home starts
there, so the shell does not manufacture Back destinations above the container.
Other remembered or explicitly requested paths still receive the process's
real permission errors; this navigation policy grants no filesystem access.
Sidebar jumps and incoming Fila links wait for the same handshake. Applications
and its private-framework lookups remain unavailable while the backend is
unknown and while it reports container reach.

Every page in a tab — a folder, a share, a catalogue and its entries, a
viewer, Search, Properties, a terminal — is a `TabContentViewController`
(`FilaBackendUI`), and the bars are the base's layout, not the page's: Back
and Places leading in the navigation bar from the shell, the page's actions
trailing; search leading in the bottom bar, the breadcrumb in the centre,
Tabs trailing. The shell's `TabNavigationController` tells a page it is in a
tab before the push, which is what puts Tabs on it; a page in a sheet is
never told and shows no Tabs. The breadcrumb is read through
`TabContentDecorationSource`: a page conforms when it knows where it is, or
is given a source that does — `LocalPathDecoration` for a local path,
`DetailDecoration` for a page about part of another page or a remote
snapshot under its share's crumbs. A catalogue's first crumb is its sidebar
artwork and name, so Applications and Music read the same way a folder does.

There was an embedded File Provider — a replicated extension serving one
chosen folder to the Files app — and it is gone. The system owns the replica
in that design, and a root file manager's folders are not replicable: the
extension had no daemon admission entitlement and could only ever export what
`mobile` could already reach, which made "choose the folder Files shows" a
promise it could not keep outside the app's own container. The App Group
survives it, because `FilaSaveAction` shares that container.

**What degrades, and to what.** `SystemCapabilities` is the one place that says
whether a feature is offered, and it now asks exactly one question: what the
environment permits. The environment side reads the live `hello`, never
`daemonIsInstalled`. There are no user switches in front of it — a feature the
handshake says is available is offered.

| Feature | Sandboxed local | Unsandboxed local | Daemon |
|---|---|---|---|
| Applications page, `.app` names and icons | hidden (`.local(.container)`) | LaunchServices, scan fallback | same |
| Run submenu / terminal | hidden | hidden (daemon only) | offered |
| Trash | `<volume>/.fila-trash` — cross-volume copy then remove; read-only reports errno | same | `<install root>/.fila-trash` on rootless and roothide, `<volume>/.fila-trash` rootful |
| Compress / extract | `ArchiveJob` in-process | same | `fila-archive`, spawned by `filad` per job; progress over the helper's stdout, then XPC |
| WebDAV | fine on a bound port ≥ 1024; publishes what the process can read | same | same |
| Temporary workspace | the app's own `tmp/wiki.qaq.fila/<UUID>` (`FileSession`) | same | same app-container workspace |
| `FilaGuard` | still enforced in-process | same | in the daemon |

**What must not happen.** No build flag or per-packaging source variant to
tell the environments apart. No fake daemon in the app. No *Connecting…*
forever in a build with no daemon — the grace period ends it. No failure
screen for a missing daemon on a jailbroken device. No feature that fails by
taking the shell down with it: a private call that returns nothing falls back
(`ApplicationCatalog.load` → bundle scan → empty page that says so).

Open items for this mode — rebinding after fallback, LiveContainer
verification, a sandboxed Applications row — live in `Roadmap.md`.

## Backends: one shell, many sources

This is the shape the app has, not a proposal. The extraction shipped in
phases through 0.4.x; what follows describes the result. Remote networking
stays in the app, over the MIT-licensed `kishikawakatsumi/SMBClient`, vendored
at `Packages/SMBClient`. FTP and SFTP are not implemented and not planned —
libcurl was evaluated for them and is not linked; `Scripts/build-libcurl.sh`
survives as a record of that evaluation and nothing calls it.

The system already carried unsolicited job progress and search results from
service to client. Directory freshness is separate: the browser also reloads
from `OperationCenter` completion notifications. Both requests and directory
subscriptions are part of the common browser-facing service contract.

`FilaBackendKit` owns the shared file-service and backend contracts, the
preference-storage contract and the small root/location/sidebar values.
`FilaClient`'s internal `FileService` is now `LocalFileAccess` — the name
`FileService` belongs to the backend-neutral protocol in `FilaBackendKit`, so
old references to it mean something else today. `DaemonLink`, in
`FilaPrivileged`, still chooses the daemon or the in-process local backend.
`FilaLocal` owns the reusable local backend classes and public in-process
access; `FilaPrivileged` holds the XPC and privileged-local selection that used
to live in `FilaClient`; `FilaSMB` implements the contract over SMBClient: one
saved share is one `SMBBackend`, its session serialises every request and
retires itself on a timeout or cancellation, directories are pulled one server
response at a time and files are read in bounded chunks into a staging
descriptor. Implementations depend on the shared contract. No module framework
is linked into filad.

Backend implementations ship as separate bundled dynamic frameworks: FilaLocal,
FilaPrivileged, FilaSMB, FilaApplications and FilaMusicLibrary, all under
`Frameworks/`. Included frameworks are
retained as startup Mach-O dependencies and loaded by dyld before main. In main,
BackendModuleDiscovery reads each embedded module's static manifest
(`FilaBackendModule.plist`), resolves
the `<framework basename>Module` entry class and registers factories/capabilities
with BackendRegistry using injected BackendHost services. The app has no
concrete-entry-class
switch, external plugin directory or third-party installation mechanism.

There is a sixth framework, and it is not a backend. `FilaCore` is one file of
`@_exported import` and no code: every FilaKit product — the contract, the
shared list base, the wire vocabulary, the file operations, the formats, the
UI libraries — is linked **once**, there, and re-exported. `FilaBackendKit` and
`FilaBackendUI` are SwiftPM libraries inside it, not frameworks of their own;
`import FilaClient` anywhere in the app resolves to the copy in
`FilaCore.framework`. Linking those products from two images would give the
process two copies of every class, which Swift conformance lookup and the
Objective-C runtime both handle badly. Every composition embeds `FilaCore`.

FilaLocal has no dependency on FilaPrivileged. Privileged access is registered
through shared contracts, then backend factories are resolved after all module
registrations. Applications and Music carry their complete feature UI, screens
included, inside their own framework directory. All first-party frameworks
ship with exactly the app's marketing version/build and shared toolchain.

This is startup code loading with demand-driven connections/queries. Module
registration does not create screens or start network/catalog I/O. Strong-link,
embedding, signing and iOS-floor checks must catch failures that would happen
before main; runtime discovery cannot recover from a missing required dylib.
Manifest, version or registration failure logs `backend failed to bootstrap`
with the module identity/reason, then omits its capabilities and entries without
an in-app alert or failed row. Persisted state is retained. This is distinct from
normal backend connection/operation errors and from on-demand daemon readiness.
All packaged modules are enabled automatically; there is no module switch or
runtime backend unload. Closing screens/subscriptions may release connections
and observation resources without unloading the backend. A bootstrap failure
disables only that launch's registration and is retried on the next startup.

A logical backend outlives its I/O connection. `LocalFileBackend` is the
extensible local class; every configured SMB share has its own
backend instance. Each owns bookmarks, recent directories and per-folder
preferences through an injected, scoped `DefaultStorage`. Production
storage remains UserDefaults. The storage adapter preserves existing local
keys and isolates remote profiles; controllers no longer edit one global
favorites array. Only global appearance/history-recording policies are shared;
sort, hidden-file visibility, default layout and domain options belong to each
backend. One SMB share is one backend instance.
`DefaultStorage`, backed by UserDefaultsStorage, is injected per process and
backend scope. App and extensions store their preferences separately; this
design introduces no cross-process defaults sharing or synchronization.

Each backend exposes an immutable root and streams a complete sidebar
contribution from its saved preferences and available locations. The app's
`SidebarModel` combines the latest contributions in stable backend order and
merges recent visits by their recorded timestamps. It does not wait for all
servers to connect, and its projection is not a second bookmark database.
Sidebar streams remain usable offline; network-directory streams may fail.
ApplicationBackend and MusicLibraryBackend contribute their own catalog roots
and snapshots; Settings and task controls remain composed by the shell.
Applications and Music have no favorite feature. Sidebar collects contributions
into common sections with deterministic ordering; cross-section reordering is
not supported.

The common protocol is `Backend`. `FileBackend` refines it for local and SMB
operations; ApplicationBackend and MusicLibraryBackend conform to Backend
without pretending applications and tracks are POSIX files — that distinction
is the reason there is a `Backend`/`FileBackend` split at all rather than one
protocol with optional halves. Each owns typed
preferences and domain actions over its existing services. Per-backend screen
factories keep the common shell independent of concrete feature imports: the
shell routes by backend identity and never imports a concrete backend to
switch on its class.

| Type | Kind | Owns |
| --- | --- | --- |
| `Backend` | Main-actor protocol | Stable identity, its `BackendRoot`, and its own sidebar snapshot stream |
| `FileBackend` | Refines `Backend` | File favourites and history, and obtaining a `FileService` |
| `LocalFileBackend` | Class conforming to `FileBackend` | The local root, scoped preference storage, local I/O |
| `SandboxedLocalFileBackend` | Final subclass | A container root and in-process-only authority |
| `SMBBackend` | Final class conforming to `FileBackend` | One saved share, its preferences, a lazy session |
| `ApplicationBackend` | Final class conforming to `Backend` | Installed applications, their preferences, their actions |
| `MusicLibraryBackend` | Final class conforming to `Backend` | Library tracks, music preferences, import/export/delete |
| `SidebarModel` | Main-actor class | Registration, subscriptions, the merged sidebar — no domain storage |

UI reuse comes through `BackendListViewController<Item>`, specialised by
`FileBrowserViewController` (files, every backend), `ApplicationListViewController`
and `MusicLibraryViewController`. There is no browser subclass per file
backend: local, sandboxed-local and SMB are the same controller with a
different injected `FileBackend`. Applications and Music specialise because
their rows and actions genuinely differ, not because their transport does. The
base holds row configuration, the loading and subscription inputs, selection
and genuinely different controls — never a per-domain switch, a global
preference read or a string-command dispatch.

`SandboxedLocalFileBackend` is a thin subclass of `LocalFileBackend`: it supplies
a container root, in-process access and appropriate defaults while inheriting
preference/sidebar behavior and shared file machinery. BackendRoot describes
the navigation root; the backend's actual authority enforces access. Container
favorites use relative paths under a stable root identity. Its default root is
Documents; full local access retains appropriate built-in roots/locations.
Additional user-created local roots are out of scope. Existing import/export
and shared-container workflows remain intact. The normal root daemon is not
confined to Documents or its bootstrap by this design.

The sandboxed IPA excludes ApplicationBackend and MusicLibraryBackend at
compile, link and embed time, including their native bridges, controllers and
indirect dependencies. `FilaApplications` and `FilaMusicLibrary` appear only
in the full composition. The app target `FilaSandboxed` excludes
`FilaPrivileged` as well: it is a second application target over the same
`Fila/` sources that links and embeds `FilaCore`, `FilaLocal` and `FilaSMB` alone, built
into its own DerivedData by `make build-sandboxed`, and `make ipa` packages
it. The existing `Fila` target serves the deb and tipa with runtime backend
selection. This revises the former shared-app-binary assumption for the
ordinary IPA without forking shared implementation or adding protocol
selection flags in feature code: nothing in `Fila/` knows which target it is
in. `Scripts/verify-composition.sh` reads the composition back out of every
packaged bundle — the embedded frameworks, the executable's load commands,
and the class and private-framework strings of the excluded modules in
every Mach-O — and packaging fails on the wrong one. App Store suitability
still requires a separate full binary/API audit.

The common contract covers bounded pull-based directory listing, item details, content
copying into a caller-owned private staging descriptor, and independent
per-directory invalidation subscriptions. Local descriptors, POSIX metadata,
root operations and trash retain their specialized interfaces. Remote files
are not represented by fake descriptors or fabricated `lstat` fields.

An invalidation means “query this directory again.” Each subscriber receives
an initial invalidation after observation is installed, buffers at most one
pending hint, and retains hints received during an in-flight listing. A stream
is created for each subscriber; one shared AsyncStream is not a broadcast bus.
Navigation cancels subscriptions and rejects stale responses. Connection loss
ends affected streams; retry establishes a new observation and full listing.
These hints are not a replacement for job lifecycle or search-result streams.

The SMB library has no CHANGE_NOTIFY. Its subscriptions use observed-directory
polling and known mutation outcomes. Local native watching can later add
bounded XPC subscriptions without changing the common consumer API. Any such
watch remains owned and authorized by the backend; filad sends metadata only.

The local browser kept its paged initial listings and its specialised file
actions through the extraction, and each screen has exactly one reload owner. `OperationCenter` continues owning task receipts, and
local publication continues through guarded atomic file operations.

Cross-backend Copy/Move is coordinated by one FileTransfer executor under
OperationCenter. Native local operations keep their existing bulk jobs;
remote routes perform any necessary download/upload internally, using bounded
per-file staging. A move publishes the complete destination before attempting
verified source cleanup. Failed cleanup retains the copy and reports a partial
move; cancellation does not erase already-published destinations. Backend-aware
clipboard snapshots are consumed only after successful moves. Application/music
domain actions stay explicit and do not acquire destructive Cut/Paste semantics.

## Testing

`make harness` runs `swift test --package-path Packages/FilaKit` against a
real filesystem on a Mac, then `Scripts/test-music-import.sh` for the
music-library fixtures. It needs no device and no simulator. It covers path
normalisation, ancestry, the guard's decisions, the symlink assumptions the
guard depends on, and — because `FilaFileOps` is a package target rather than
code buried inside the daemon — the POSIX layer's own error mapping; the jobs
themselves join it as they land. Nearly every module has a test target: the
exceptions are `FilaBackendUI`, which is UIKit, and the C shims.

The SMB suite is the one that needs something outside the repository.
`SMBLiveServerTests` runs against a real share when
`FILA_SMB_SERVER=host:port` is set, with `FILA_SMB_SHARE`, `FILA_SMB_USER`,
`FILA_SMB_PASSWORD` and `FILA_SMB_FIXTURES` (the directory the share exports,
so the tests can lay down what they then list and read). Without
`FILA_SMB_SERVER` every one of them skips rather than fails — a green harness
does not by itself mean SMB was exercised. impacket's
`smbserver.py -smb2support` on a high port is enough to run them and needs no
privileges; the share must be writable, because `SMBLiveWritingTests` writes
through it and reads the result back off disk.

A jailbroken device or VM is where the privileged half is proved: XPC,
entitlements, launchd, and the bootstrap layouts. The in-process backend
covers the shell, not that path.
