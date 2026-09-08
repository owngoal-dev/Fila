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
`Reach.user` (unsandboxed: the `.tipa`).

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

The embedded File Provider is a replicated extension (iOS 16; its
`MinimumOSVersion` keeps it out of Files on 15). The system owns the on-disk
replica, downloads, conflicts and upload state; the extension answers metadata,
hands out content and applies mutations. The main app initializes the default
source to its own private Documents folder, records the choice as a resolved
path in the configured App Group, and registers one domain named "Fila" at
launch. Changing the folder removes and re-adds the domain, which on iOS drops
unsynced edits, and the settings page says so. Selection requires real process
access; it does not transfer the daemon's privileges.

`ProviderTree` identifies an item by its inode — APFS never reuses one — so a
rename or move keeps the item and its replica and changes only the metadata
version. It keeps the last reported state in
`<App Group>/.fila-provider/<generation>/index.json`; the sync anchor hashes it,
and a change enumeration rescans the folder and diffs against the baseline the
anchor names. A lost index costs one re-enumeration. Mutations use the shared
file-operation layer with the folder as writable root: exclusive creation,
exclusive rename, atomic content replacement (which swaps the inode, reported as
a merge), permanent deletion, no trash. Symlinks, special nodes and multiply
linked files are not exported. The extension has no daemon admission
entitlement, and App Group membership alone grants access to no other folder.

**What degrades, and to what.** `SystemCapabilities` is the one place that says
whether a feature is offered: environment permits *and* the user has not turned
it off in Settings → System Features. The environment side reads the live
`hello`, never `daemonIsInstalled`.

| Feature | Sandboxed local | Unsandboxed local | Daemon |
|---|---|---|---|
| Applications page, `.app` names and icons | hidden (`.local(.container)`) | LaunchServices, scan fallback | same |
| Run submenu / terminal | hidden | hidden (daemon only) | offered |
| Trash | `<volume>/.fila-trash` — cross-volume copy then remove; read-only reports errno | same | `<install root>/.fila-trash` on rootless and roothide, `<volume>/.fila-trash` rootful |
| Compress / extract | `ArchiveJob` in-process | same | `fila-archive`, spawned by `filad` per job; progress over the helper's stdout, then XPC |
| WebDAV | fine on a bound port ≥ 1024; publishes what the process can read | same | same |
| Temporary workspace | the app's own `tmp/wiki.qaq.fila/<UUID>` (`FileSession`) | same | same app-container workspace |
| `FilaGuard` | still enforced in-process | same | in the daemon |

The user-side switches exist because a jailbreak without a full
system-protection bypass can make a private-framework call hang or crash
rather than fail: turning the feature off means the call is never made.

**What must not happen.** No build flag or per-packaging source variant to
tell the environments apart. No fake daemon in the app. No *Connecting…*
forever in a build with no daemon — the grace period ends it. No failure
screen for a missing daemon on a jailbroken device. No feature that fails by
taking the shell down with it: a private call that returns nothing falls back
(`InstalledAppCatalog.load` → bundle scan → empty page that says so).

Open items for this mode — rebinding after fallback, LiveContainer
verification, a sandboxed Applications row — live in `Roadmap.md`.

## Testing

`make harness` runs `swift test --package-path Packages/FilaKit` against a
real filesystem on a Mac. It needs no device and no simulator. It covers path
normalisation, ancestry, the guard's decisions, the symlink assumptions the
guard depends on, and — because `FilaFileOps` is a package target rather than
code buried inside the daemon — the POSIX layer's own error mapping; the jobs
themselves join it as they land.

A jailbroken device or VM is where the privileged half is proved: XPC,
entitlements, launchd, and the bootstrap layouts. The in-process backend
covers the shell, not that path.
