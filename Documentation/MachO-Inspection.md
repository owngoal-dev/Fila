# Mach-O inspection

The inspector uses the app-side `FilaFormats.MachOImage` reader over a
descriptor from the local backend: `MachOInspectorViewController` is handed a
`DescriptorFile` and an `any LocalFileAccess`. Do not read the older name
`FileService` here — that protocol still exists, but it is now the
backend-neutral one in `FilaBackendKit`, which deliberately has no descriptors,
so naming it would point at the wrong contract. The former UIKit parser is
removed. No path is reopened, no file is mapped by a dependency, and no
executable content enters `filad`.

[MachOKit](https://github.com/p-x9/MachOKit) supplies typed
load-command layouts, header flags, protection flags, platforms and version
decoding. `Package.swift` declares `from: "0.52.2"`, a minimum rather than a
pin; `Package.resolved` names the version actually built. These drive the displayed command list, segments and sections,
deployment/SDK versions, entry offset and symbol count. The adapter also
reads bounded signature identity fields and preserves entitlement viewing.
MachOKit is a dependency of `FilaFormats` only; it does not link into the daemon.

The adapter does not use the library's URL-based `MachOFile` initializer or
its live-process reader. Its load-command iterator receives one copied,
validated command at a time, from a whitelist of fixed layouts. Strings and
section names are read within their byte ranges rather than through unsafe
pointer helpers. The legacy minimum-version SDK accessor in this release
repeats the minimum version; the adapter reads the actual SDK word instead.

The reader limits universal files to 64 slices, each command region to 16 MiB
and 16,384 commands, signature indices to 64 entries, signing strings to
4 KiB, and entitlement payloads to the property-list reader's size limit.
Slice arithmetic, command alignment, typed-layout sizes and referenced
segment/symbol ranges are checked before decoding. File size does not imply
a whole-file allocation. The UI parses on a cancellable worker and closes its
duplicated descriptor when that worker ends.

Tests inspect a system binary, inspect an already-open file after its name is
unlinked, inspect a sparse 4 GiB file with an empty command region, and reject
truncated structural input. This is a structural viewer: it does not verify
cryptographic trust or modify executable bytes.
