# Where a directory listing spends its time

Measured on the vphone on 2026-09-10, against a Release build of 0.4.7
(build 118) with the privileged backend (`filad`) — the shipping composition,
not the simulator's in-process one. This is a research note: nothing here was
optimised, and the candidate fixes at the end are unimplemented.

**One sentence:** on a warm directory the listing is *app-side* bound — two
thirds of the wall clock is the main thread inside `applySnapshot`, and the
daemon idles through it — while on a cold directory the daemon's per-entry
`fstatat` and the metadata reads underneath it dominate. Nothing is
overlapped: the backend and the main thread take strict turns.

## Method

Two instruments, chosen because they need nothing installed on the device:

- **Daemon side:** `sudo fs_usage -w -f filesys filad` on the device, which
  gives one line per syscall with its elapsed time, plus the `RdMeta[S]`
  disk reads nested inside them. It also shows *idle gaps* in the daemon,
  which are exactly the intervals where the app is holding the pipeline.
- **App side:** a temporary patch to `BackendListViewController` — reverted,
  never committed — timing three things and appending them to a file in the
  app's own `NSTemporaryDirectory()`, which is readable over SSH:
  - `page N n=… wait=…` — from "asked for a page" to "page in hand",
    i.e. XPC round trip + daemon work + decoding the page's `FileNode`s;
  - `apply n=… arrange=… snapshot=… diff=…` inside `applySnapshot`, and the
    whole synchronous duration of `applySnapshot`;
  - `load end received=… total=…` and the duration of `loadDidComplete`.

Navigation was driven without taps: `uiopen 'fila://open?path=…'` over SSH,
with `killall Fila` before each run so every measurement is a fresh listing
rather than a cached tab.

Reproduce (see also the vphone notes at the end):

```bash
ssh mobile@<vphone>            # password alpine
killall Fila
sudo sh -c 'timeout 20 fs_usage -w -f filesys filad > /tmp/fsu.txt 2>&1 &'
uiopen 'fila://open?path=/System/Library/PrivateFrameworks'
```

Caveat worth stating: `fs_usage` itself costs something per syscall, so the
absolute daemon numbers are an upper bound. The app-side numbers are taken
without it running and are not affected.

## What was measured

Three runs. Two on a real directory of moderate size, one on a synthetic
20 000-entry directory created for the purpose (`/var/mobile/perftest`,
removed afterwards) — because the interesting behaviour is how the cost
scales, and 2 900 entries is not where a file manager hurts.

### Run A — 2 900 entries, cold (`/System/Library/PrivateFrameworks`, first visit)

Daemon burst, from `open(2)` on the directory to `close(2)`: **261 ms wall.**

| what | count | total | per call |
| --- | --- | --- | --- |
| `fstatat64` | 2 935 | 132.4 ms | 45.1 µs |
| — of which `RdMeta[S]` (disk) | 870 | 106.2 ms | 122.1 µs |
| `getdirentries64` | 20 | 1.1 ms | 55.9 µs |
| `readlinkat` | 35 | 0.1 ms | 1.5 µs |
| **daemon syscalls** | | **133.7 ms** | |
| **idle gaps inside the burst** | 2 | **121.1 ms** | 64 ms, 57 ms |

Then a further ~90 ms gap after `close(2)` before the `statfs64` of
`loadVolume` — that is the final `applySnapshot`.

So on a cold folder the daemon's own work is about half the listing, and
**80 % of that daemon work is `RdMeta` — reading metadata off the disk**, not
CPU. The two idle gaps are the app's snapshot applies; the daemon sits doing
nothing through both.

### Run B — the same 2 900 entries, warm

Daemon burst: **97.7 ms wall**, of which syscalls are only **18.9 ms**
(`fstatat64` drops from 45.1 µs to **5.9 µs**), and **71.7 ms is idle gap**.
Same directory, same entries; the whole difference is the page cache.

App side, same run:

```
load begin keepsContent=false
page 1 n=512  wait=4.7ms
applySnapshot sync total=43.6ms n=512
  apply n=512   arrange=1.3ms  snapshot=0.4ms  diff=54.8ms
page 2 n=512  wait=21.0ms
page 3 n=512  wait=4.6ms
page 4 n=512  wait=3.8ms
page 5 n=512  wait=3.9ms
page 6 n=340  wait=2.6ms
applySnapshot sync total=41.0ms n=2900
  apply n=2900  arrange=9.4ms  snapshot=2.2ms  diff=37.0ms
load end received=2900 total=133.3ms
loadDidComplete=60.2ms
```

| phase | time | share of the 133 ms |
| --- | --- | --- |
| backend (XPC + daemon + decode), 6 pages | 40.6 ms | 30 % |
| `applySnapshot` #1 (512 rows) | 43.6 ms | 33 % |
| `applySnapshot` #2 (2 900 rows) | 41.0 ms | 31 % |
| everything else in the loop | ~8 ms | 6 % |
| *then* `loadDidComplete` | *60.2 ms* | *(after "load end")* |

`loadDidComplete` is not inside the 133 ms but the user is still waiting for
it: it is `SystemCapabilities.applications.decorations(in:)` plus
`volumeInfo`, and it costs as much as everything before it.

### Run C — 20 000 entries, warm (`/var/mobile/perftest`, 40 pages)

Two runs, 533.4 ms and 545.4 ms end to end (`purge` between them changed
nothing measurable — these files' metadata stayed cached). Numbers below are
the second run.

| phase | time | share |
| --- | --- | --- |
| backend wait, 40 pages | 175.2 ms | 32 % |
| — of which daemon syscalls (`fs_usage`) | 79.0 ms | 14 % |
| — of which XPC transport + `FileNode` decode | ~96 ms | 18 % |
| `applySnapshot` × 4, synchronous, on the main thread | 358.8 ms | 66 % |
| — of which `arrange(_:)` (sort + filter) | 180.2 ms | 33 % |
| — of which building the snapshot | 33.8 ms | 6 % |
| — of which `UICollectionViewDiffableDataSource.apply` + cells | ~145 ms | 27 % |
| *then* `loadDidComplete` | *42.6 ms* | |

The four applies, in order: 51.3 ms (512 rows), 91.4 ms (10 752), 115.5 ms
(19 456), 100.6 ms (20 000). The `arrange` inside them: 1.3, 37.1, 68.3,
73.5 ms — each one re-sorts the **whole accumulated array from scratch**,
which is what the 0.15 s throttle in `reload()` is there to limit.

Daemon syscalls for the same run: `fstatat64` × 19 854 = 72.0 ms (3.6 µs
each), `getdirentries64` × 99 = 6.0 ms. Per entry the daemon costs about
**4 µs warm and 45 µs cold**; the app costs about **18 µs per entry** on top,
at every size measured.

## Conclusions

1. **Warm listings are main-thread bound, not daemon bound.** 66 % of a
   20 000-entry listing is `applySnapshot`. The daemon's own syscalls are
   14 %.
2. **Cold listings are I/O bound in the daemon.** `fstatat` per entry costs
   45 µs cold against 5.9 µs warm, and 80 % of that is `RdMeta` — one
   metadata read per entry, unbatched.
3. **The pipeline is strictly serial.** `DirectoryReader` is pull-based, so
   the daemon idles for the whole of every apply (visible as the 64 ms and
   57 ms gaps in the `fs_usage` trace) and the main thread idles for the whole
   of every page fetch. At 20 000 entries that is 175 ms of backend and 359 ms
   of main thread that never overlap.
4. **Sorting is the single biggest app-side line item at scale** — 180 ms of
   533 ms. `arrange(_:)` runs `localizedStandardCompare` over the whole
   accumulated list on every apply. Measured on the host for the same 2 900
   names: `localizedStandardCompare` sort 9.5 ms, plain `<` sort 0.4 ms,
   sort on a precomputed lowercased key 0.5 ms — the comparator is **24×** a
   plain string compare, and it is paid n log n times per apply.
5. **There is a fixed cost per apply that has nothing to do with the item
   count.** The first apply of 512 rows costs 44–51 ms while its `arrange` is
   1.3 ms; the rest is the diffable apply and materialising the first screen
   of cells. Applying more often would not be free even if sorting were.
6. **`loadDidComplete` adds 43–60 ms after the list is already complete**,
   and it is on the user's path to a settled screen: app decorations for the
   whole directory plus `volumeInfo`.
7. Time to *first rows* is good — about 50 ms in every run — so the problem
   is not the wait for the first page but the two to four main-thread stalls
   of 40–115 ms that follow it, which are also what makes a big folder feel
   like it janks while it loads.

## Candidate optimisations (not implemented, in rough value order)

Each of these is a hypothesis with a number behind it, not a plan. Anything
touching the file layer goes through `/code-clarity` and `/code-review` per
the repository rules.

1. **Stop re-sorting the accumulated array on every apply.** Sort each page
   once and merge into the sorted list, or accumulate unsorted and sort once
   at the end. Worth up to ~140 ms of the 180 ms at 20 000 entries.
   *Constraint:* `arrange` also de-duplicates by name and filters hidden
   entries, and pages come from a live directory — a merge has to keep both.
2. **Overlap the backend with the main thread.** One page of read-ahead while
   an apply runs would hide most of the 175 ms of backend wait behind the
   359 ms of apply. *Constraint:* the pull model is deliberate (a slow UI must
   not queue unbounded pages, and dropping the iterator closes the directory);
   a lookahead of exactly one page keeps that property.
3. **A cheaper comparator.** A precomputed sort key per entry instead of
   `localizedStandardCompare` per comparison. *Constraint:* the ordering is
   user-visible and locale-and-numeric aware ("file2" before "file10"); any
   key has to reproduce it exactly, which a naive `lowercased()` does not.
4. **`getattrlistbulk(2)` in `DirectoryListing`.** One syscall per ~100
   entries fetching name and attributes together, instead of `readdir` +
   `fstatat` per entry. This is the lever for the cold case: 2 900 separate
   metadata reads is what the 106 ms of `RdMeta` is. *Constraint:* it must
   return everything `FileNode` carries (`st_flags`, `st_blocks`, birth time,
   link count, inode) and keep the `AT_SYMLINK_NOFOLLOW` semantics; and this
   is file-layer code, so the review gate applies.
5. **A denser page encoding.** ~96 ms at 20 000 entries is XPC transport plus
   `FileNode(decoding:)` per entry out of an `xpc_array` of dictionaries —
   about 5 µs an entry. A flat binary blob with the strings packed after a
   fixed-size record array would cut most of it. *Constraint:* the wire
   vocabulary is shared with the daemon and the 6 MB jetsam cap still applies
   — a page is 512 entries, so a blob stays small.
6. **Move `loadDidComplete`'s decorations off the critical path** — per page,
   or off the main thread, so the 43–60 ms is not appended to the listing.
7. **Re-tune the 0.15 s apply throttle** once 1 and 2 land. It exists to limit
   how often the whole list is re-sorted; with an incremental sort the right
   trade-off is different.

## What was not measured

- A physical device. The vphone's storage is a disk image on an SSD-backed
  host, so the cold `RdMeta` numbers are optimistic against real NAND, and
  the CPU is host-speed.
- The in-process backend (`.ipa`/`.tipa` composition). Only the daemon path
  was profiled; the app-side half of these numbers applies to both, the XPC
  line does not.
- Scrolling and cell reuse after the listing settles. Everything here is the
  load, not the browse.
- The grid layout — every run was the list layout.
- `FileSearch` and the tree walk, which have their own cost model.

## Reproducing on the vphone

The VM answers SSH on its bridge address (2026-09-10: `192.168.64.2:22`,
`mobile`/`alpine`) when no `iproxy` forward is running. It has no `log`,
`defaults`, `awk` or `python3`, but it does have `fs_usage`, `sc_usage`,
`latency`, `stackshot`, `htop`, `uiopen` and `sudo`. Install a Release build
without the release gates:

```bash
make _build-ios _package-deb CONFIGURATION=Release FLAVOR=rootless
DEVICE_HOST=192.168.64.2 DEVICE_PORT=22 DEVICE_USER=mobile DEVICE_PASSWORD=alpine \
  Scripts/install-device.sh build/Packages/wiki.qaq.fila_0.4.7_iphoneos-arm64.deb
```

The app-side instrumentation was a temporary patch to
`Packages/FilaKit/Sources/FilaBackendUI/BackendListViewController.swift`:
timestamps around `arrange`, the snapshot build and `dataSource.apply`'s
completion inside `applySnapshot`; a `wait=` line per batch in `reload()`;
and a `PerfTrace` helper appending to `NSTemporaryDirectory() +
"fila-perf.log"`. It is not in the tree — re-apply it when these numbers need
to be taken again.
