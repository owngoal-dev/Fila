# SMBClient, vendored

Upstream: https://github.com/kishikawakatsumi/SMBClient
Revision: `66eafaa6d17e034e8036dee4b3ebc1b52cb53919` (main, 2026-04-27)
Licence: MIT, `LICENSE` beside this file, unchanged.

Why a copy rather than a package reference: `Session.queryDirectory` collects
a whole directory into one array before it returns, and every request
primitive under it is `private`. Fila lists remote directories one server
response at a time so a listing can be budgeted and cancelled between pages,
which needs one method inside the module. Everything else is upstream as-is.

Why this revision rather than the last tag (0.3.1, 2024-12-10): the commits
since fix a large-download stall in the `NWConnection` receive loop, a crash
on a partial DirectTCP header, a retain cycle in the state handler and a
double resume of a continuation. All four are in the transport every
operation goes through.

What was left out: `Tests/` (44 MB of fixtures and a mock server),
`Examples/`, the Docker files and the README. The library builds and tests
under Fila's own harness.

## Changes

`Sources/SMBClient/Session.swift`: added `queryDirectoryPage(fileId:pattern:restart:)`
after `queryDirectory(path:pattern:)`. One QUERY_DIRECTORY request against a
directory handle the caller opened with `create` and closes with `close`;
returns the entries of that response and whether the server has more. Marked
`// Fila:` in the source. Nothing existing was modified.

`Sources/SMBClient/Session.swift`: added `rename(from:to:replaceIfExists:)`
after `move(from:to:)` — the same compound with the rename's replace flag
exposed, so a publication can be exclusive (an occupied name fails and
nothing moves) or a replacement, as the caller decided. `setInfo(path:_:)`
opens without DELETE access and cannot rename.

`Sources/SMBClient/Session.swift`: added `deleteNode(path:directory:)`
after it — delete-on-close of exactly one node, with the create options
pinning the kind and opening a reparse point as itself. Upstream's
`deleteDirectory(path:)` lists and deletes a directory's contents first,
which a move's source cleanup must never do. Both marked `// Fila:`.

`Sources/SMBClient/Connection.swift`: `Connection` is declared
`@unchecked Sendable`. Its send completion is a `@Sendable` closure that calls
back into `receive`, which warns about capturing a non-Sendable `self` — the
only warning the harness reports in this copy. Nothing else changed; the
reason the claim holds is in a `// Fila:` comment above the declaration.

## Updating

Check out the new upstream revision, copy `Sources/SMBClient` and `LICENSE`
over this directory, reapply the change above, update the revision here, and
run `make harness`.
