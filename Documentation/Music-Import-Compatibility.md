# Music import compatibility

Fila uses MusicLibrary's client importer on iOS 15 and later. The system owns
library writes, artwork registration, artist/album grouping and notifications.
Fila does not issue SQL updates. Diagnostic database queries are read-only.

## Failures corrected in 0.4.1

The iOS 18.5 importer rejects three hints that newer versions expose:
`ML3ClientImportSessionConfiguration.shouldLibraryAdd`,
`MIPAlbum.artworkSourceType`, and `MIPMediaItem.artworkSourceType`.
The same setters are absent from the iOS 15.5, 16 and 17.0.3 header dumps.
Only these optional hints use a setter capability check. Required metadata
remains strict; exceptions from an available setter remain errors.

The legacy importer registers artwork with source 0, while newer importers
honor source 500. Even on iOS 18.5, `populateArtworkCacheWithArtworkData:`
looks for source 500. The bridge instead resolves the token actually attached
to the new track and passes that source to the native original-artwork writer.
It writes separate album artwork only when that album has the matching token;
an existing album's unrelated cover is not overwritten.

The iOS 18.5 importer also accepts `isInUsersLibrary` while leaving the saved
track's library membership false and date added zero. Those rows exist but do
not appear in the system Music library. After attaching the audio and artwork,
Fila fills missing membership and date-added properties through native setters,
then rereads the saved track before reporting success.

Existing import directories are checked before creation. An EEXIST race is
still verified as a directory; other failures propagate. Once a native commit
has been attempted, an uncertain failure retains the audio instead of deleting
a file the library may already reference. A later MediaPlayer refresh failure
also cannot trigger cleanup of a successfully imported file. Existing records
from earlier failed attempts are not automatically deleted or rewritten.

## Refresh and presentation

MusicLibrary may finish a write before MediaPlayer invalidates its cache.
Import and deletion now wait for a fetched song list that contains or excludes
the affected persistent ID. Polling is cancellable and bounded to ten seconds;
a timeout reports an unconfirmed update, without publishing an optimistic list.

The progress card stays until that fetched snapshot finishes applying. Pending
older loads are cancelled, and background notifications cannot reload during a
mutation. Loaded content stays visible during later background fetches, including
an already loaded empty library. Identical rows do not animate again. Diffable
snapshots use persistent IDs and reconfigure changed metadata. Song rows show
artwork, title, artist and duration, with native detail-disclosure controls. Wide
rows include the album beside the artist; narrow rows omit it. A shared rounded
placeholder uses a small music note until artwork is available. Song details
include a large cover preview and keep that preview through field refreshes;
the details screen has no tab-switcher toolbar item.

## Evidence and limits

- iPad8,9, iOS 18.5 (22F76), RootHide: reproduced the missing setters,
  artwork source mismatch, and membership false/date-added zero. The corrected
  import produced membership true and a nonzero date. The device owner confirmed
  display and playback in the system Music app.
- vphone, iOS 26.6.1 (23G83), rootless: imported files with and without artwork,
  verified a red cover in Music, and edited metadata. The VM has no audio output
  device, as confirmed by its owner; it does not establish successful playback.
- iOS 15.5, 16 and 17.0.3 header inspection checks interface availability.
  It does not establish runtime behavior for every iOS 15+ minor release.
- `make harness` includes the production Objective-C boundary regression test:
  missing optional hints, strict required fields, rejecting available setters,
  source 0/500 token resolution, and preservation of unrelated album tokens.
- Release validation includes project/localization checks, host tests, all four
  package verifiers, and the binary dependency/deployment audit for iOS 15.0.

## Header references

- [iOS 15.5 MusicLibrary headers](https://github.com/lechium/iPhone_OS_15.5/tree/master/System/Library/PrivateFrameworks/MusicLibrary)
- [iOS 16 MusicLibrary headers](https://github.com/qingralf/iOS16-Runtime-Headers/tree/main/PrivateFrameworks/MusicLibrary.framework)
- [iOS 17.0.3 MusicLibrary headers](https://github.com/MTACS/iOS-17-Runtime-Headers/tree/main/PrivateFrameworks/MusicLibrary.framework)

## iPad deletion incident, 2026-09-08

The iOS 18.5 device reported a stuck query after a deletion. At 22:45:21 the
client import session removed one track and committed; a concurrent library
reader then reported `SQLITE_IOERR_SHORT_READ` (522). MusicLibrary's recovery
unlinked the shared-memory file while Fila, atc, Music and medialibraryd still
held it, and Music subsequently crashed with a database I/O exception. A raw
copy of the database plus WAL passed `PRAGMA integrity_check` on the host.
The library service was restarted; its previously queued recovery request then rebuilt the live library empty. Audio files and the host backup remain preserved. The owner confirmed these were test records and requested keeping the empty library.
This establishes the failure sequence, not the underlying cause of the first
short read. The revised single-entity deletion path passes host boundary tests; device regression testing of deletion followed by queries remains outstanding. The owner requested starting the 0.4.2 release workflow with this limitation recorded.
