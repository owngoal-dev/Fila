# Where a directory listing spends its time

Measured on the vphone on 2026-09-10, against Release builds with the
privileged backend (`filad`) — the shipping composition, not the simulator's
in-process one. The first half is the profile of 0.4.7 build 118 as it was;
the second half is the same folders after the listing was rebuilt around it,
with the numbers side by side.

**One sentence, before:** on a warm directory the listing was *app-side*
bound — two thirds of the wall clock was the main thread inside
`applySnapshot`, and the daemon idled through it — while on a cold directory
the daemon's per-entry `fstatat` and the metadata reads underneath it
dominated; nothing overlapped, and the listing did not even start until the
push animation had finished.

**One sentence, after:** the listing starts before the push, the push waits
at most 50 ms for the first rows and lands on them, the app reads the
directory itself over a descriptor the daemon opened as root, and no apply
holds the main thread for more than the budget a push waits for.

## Method

Two instruments, chosen because they need nothing installed on the device:

- **Daemon side:** `sudo fs_usage -w -f filesys filad` on the device, one
  line per syscall with its elapsed time, plus the `RdMeta[S]` disk reads
  nested inside them. It also shows *idle gaps* in the daemon, which are
  exactly the intervals where the app is holding the pipeline. Used for the
  "before" profile only; the daemon does almost nothing per listing now.
- **App side:** the listing trace that is now permanent in
  `BackendListViewController`, at verbose level. Every load writes the wait
  for each batch (`batch N n=… wait=…`), the cost of each apply split into
  the arrange (sort and filter, off the main thread when the screen can say
  how), the `apply`/`diff` handed to the diffable data source, and the
  `hooks` (status panel and `snapshotDidApply`) — and, for the final apply of
  a refresh, `settled=` for the animation's length, which is not the main
  thread's — then a `prepared rows=N in Xms` line when a push waited, and a
  `complete` line with the tail (`loadDidComplete`). The browser names its
  directory in every line. The log screen shows all of it; for a session
  over SSH a local patch tees `FilaLog` to `/var/mobile/fila-trace.log` and
  forces verbose (never committed; four lines in `AppDelegate`).

Navigation was driven without taps: `uiopen 'fila://open?path=…'` over SSH
into a running app (launched to `/usr/lib` six seconds earlier), so launch
contention stays out of the numbers. A link is a *jump* — the tab's stack is
replaced — and takes the same pre-push wait a tap's push takes, so the trace
shows the same path a tap would.

**Cold, repeatably.** The vphone cannot be restarted, but `kern.maxvnodes`
is 14 000 and `find /System/Library /usr /private/var/db -type f` walks
230 000 files: every vnode is recycled, and the next stat of a folder is back
to its cold figure (2 900 entries: 10.7 ms warm → 147 ms after the walk, the
same as first contact). Every "cold" run below follows that walk.

Two folders, as before: `/System/Library/PrivateFrameworks` (2 900 entries,
real) and `/var/mobile/perftest` (20 000 empty files, synthetic, because the
interesting behaviour is how the cost scales).

## Before — build 118

### 2 900 entries, cold

Daemon burst, `open(2)` to `close(2)`: **261 ms wall**; `fstatat64` × 2 935 =
132 ms (45 µs each), of which 870 `RdMeta[S]` disk reads = 106 ms; two idle
gaps of 64 and 57 ms while the app applied. Then ~90 ms of final apply, then
`loadDidComplete`.

### 2 900 entries, warm

Daemon burst 98 ms, of which syscalls 19 ms (`fstatat64` 5.9 µs each) and
72 ms idle. App side, 133 ms end to end:

| phase | time | share |
| --- | --- | --- |
| backend (XPC + daemon + decode), 6 pages | 41 ms | 30 % |
| `applySnapshot` #1 (512 rows) | 44 ms | 33 % |
| `applySnapshot` #2 (2 900 rows) | 41 ms | 31 % |
| *then* `loadDidComplete` | *60 ms* | *(after "load end")* |

### 20 000 entries, warm

533–545 ms end to end:

| phase | time | share |
| --- | --- | --- |
| backend wait, 40 pages | 175 ms | 32 % |
| `applySnapshot` × 4, synchronous, on the main thread | 359 ms | 66 % |
| — of which `arrange(_:)` (sort + filter) | 180 ms | 33 % |
| — of which the diffable apply + cells | ~145 ms | 27 % |

The four applies: 51 ms (512 rows), 91 ms (10 752), 116 ms (19 456), 101 ms
(20 000). Each re-sorted the whole accumulated array on the main thread.

### And what the numbers did not show

The listing started in `viewDidAppear`, after the push animation, through the
change subscription's first hint. A tapped folder slid in showing *Reading
Folder…* and the rows popped over it a moment later, on every folder, warm or
cold — the "blink" the rebuild was asked to remove. The trace above began
when the listing did, so none of that was in it.

## What changed

Five commits, in order, each measured on the device and reviewed by Opus 5.

1. **Decorations** (`e543d45`): `loadDidComplete` asked LaunchServices for
   the app catalogue on every folder, before the cheap "can this folder carry
   a decoration" check, and again for the breadcrumb. The check comes first,
   the catalogue is read once and kept until the handshake's backend changes,
   and the volume fetch runs beside it rather than after. The 43–60 ms tail
   is 6 ms outside a container root.
2. **Fetch before the push** (`ce41e75`, fixes in `7341e74`): the push site
   owns the wait. `TabNavigationController` gives a screen that fetches on the
   way in — any `PreparableContent` — up to `FilaUI.preparationBudget`
   (50 ms) to put its first rows up before the transition starts; whatever
   lands inside half the budget goes up together, so the rows the transition
   shows are not reordered by the batch after it. Past the budget the screen
   goes up with its loading status and the rows animate in. A jump gets the
   same wait before it replaces the stack. `BackendListViewController` can
   start its load before it is in a window, and paces its applies: one per
   120 ms after the first, each sized from what the last one cost on this
   device toward a 40 ms target and never over the budget. A screen that can
   say how it arranges as a pure value (`arranger()`) has its sorts run off
   the main thread; the browser's `FileArrangement` is that value.
3. **The app reads the directory** (`DirectoryBulkReader`, this step): with
   the daemon, the browser asks it to `open` the directory — one round trip,
   an existing operation — and reads it here with `getattrlistbulk(2)` over
   the descriptor: complete entries, about four hundred per call, and the
   daemon's pages are not involved. In a directory this process may not
   search the first call refuses before any entry — and any failure before
   the first entry, that refusal, a volume without a bulk read, a layout the
   reader does not know, hands the listing to the daemon's pages — so the
   path can only ever show less than the daemon would, never more.
   Two places the bulk read would differ from the daemon's `fstatat` are
   handled: a mount point (`/private/var`, `/dev`) is described by the
   directory it covers, so the reader asks for the mount status and takes one
   `fstatat` for such an entry; and the reader stops at the browser's entry
   cap rather than buffering a directory it will not show. `filad` changed by
   zero operations.

Not done, and known: the sort itself. `localizedStandardCompare` over 20 000
names is 60–75 ms of CPU per apply, now off the main thread; a precomputed
key would cut it, at the cost of reproducing the locale-and-numeric order
exactly. A sort-order change on a huge folder still sorts on the main thread.

## After — the same folders

Every run below is with the pre-push wait, the paced applies and the reader.
"push at" is when the transition started and with how many rows; "apply"
figures are what the main thread spent handing rows to the collection view,
the largest first.

| scenario | before | after | what the user sees |
| --- | --- | --- | --- |
| warm 2 900 | rows after the push animation; complete 133 ms; applies 44 + 41 ms | push at **40 ms with 403–2 900 rows**; complete 210–230 ms; applies ≤ 32 ms | the folder slides in populated |
| warm 20 000 | rows after the push animation; complete 533 ms; applies 51, 91, **116**, 101 ms | push at **52 ms with 4 000 rows**; complete 340–480 ms; applies ≤ 43 ms | populated on arrival; the rest fills in below the fold |
| cold 2 900 | 344 ms; first page 64 ms; applies up to 33 ms | first read 60–75 ms (disk) → push with the status at 50 ms, **rows animate in at ~+45 ms**; complete 300–325 ms | one wait, one transition, no pop-over |
| cold 20 000 | 708 ms; first page 42 ms; applies 83, 95, **102**, 91 ms | 580–625 ms; applies ≤ 41 ms | as above |
| refresh, 20 000 (a file created while on screen) | 722 ms to complete; one apply of **90 ms** (69 sort on main + 21 diff) | 580 ms to complete; sort 67 ms off main, **diff 22 ms** on main, then 445 ms of animation | the row appears; nothing stutters |

Where the remaining time goes, warm 20 000: the reader has every entry in
~45 ms (47 calls at 0.6–0.8 ms); the first 4 000 rows are applied off-window
in 8 ms and the push starts; the remaining 16 000 rows go up in four paced
applies of 29–43 ms, 120 ms apart, with a 31–69 ms sort off the main thread
before each. The end-to-end figure is the pacing, chosen so that no apply
crosses the budget; the rows a user can see are there at 52 ms.

Where it goes, cold: the disk. The first `getattrlistbulk` on a cold
2 900-entry folder is 60–75 ms (the same metadata reads the daemon's
`fstatat`s did), so a cold folder always takes the "push with the status,
animate the rows in" path. The reader's calls after the first are cheaper
than a page each was, so the cold totals fall by 10–15 %, but a cold folder
is I/O and no arrangement of the app changes that.

The main-thread cap held in every run: the largest apply on screen was
45 ms, on the first chunk after a push, when the collection view also makes
its cells. `BackendListPacing` starts at 4 000 new rows for that reason and
sizes the next chunk from the last one's cost.

## What was not measured

- A physical device. The vphone's storage is a disk image on an SSD-backed
  host, so the cold numbers are optimistic against real NAND, and the CPU is
  host-speed.
- The in-process backend (`.ipa`/`.tipa` composition). It keeps the paged
  listing; the pre-push wait and the pacing apply to it, the reader does not.
- Scrolling and cell reuse after the listing settles.
- The grid layout — every run was the list layout.
- `FileSearch`, the destination pickers and workspace cleanup, which still
  read the daemon's pages and have their own cost model.

## Reproducing on the vphone

The VM answers SSH on its bridge address (this session: `192.168.64.1:2222`,
`mobile`/`alpine`). It has no `log`, `defaults` or `python3`, but it does have
`fs_usage`, `uiopen`, `find` and `sudo`. Install a Release build:

```bash
make deb FLAVOR=rootless
DEVICE_HOST=192.168.64.1 DEVICE_PORT=2222 DEVICE_USER=mobile DEVICE_PASSWORD=alpine \
  Scripts/install-device.sh build/Packages/wiki.qaq.fila_0.4.7_iphoneos-arm64.deb --launch
```

Then, per run:

```bash
killall Fila; rm -f /var/mobile/fila-trace.log
uiopen 'fila://open?path=/usr/lib'; sleep 6            # a running app, a cheap current folder
find /System/Library /usr /private/var/db -type f | wc -l   # only for a cold run
uiopen 'fila://open?path=/System/Library/PrivateFrameworks'; sleep 10
grep -E 'list |listed ' /var/mobile/fila-trace.log
```

The tee is a local patch to `AppDelegate.application(_:didFinishLaunchingWithOptions:)`:
set `FilaLog.minimumLevel = .verbose`, then a detached task that every 300 ms
appends `FilaLog.snapshot(since:)` to `/var/mobile/fila-trace.log`. Without
it, the same lines are on the log screen at verbose.

The 20 000-entry fixture: `mkdir /var/mobile/perftest` and a shell loop
creating `file-N.txt`; remove it afterwards.
