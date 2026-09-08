# Music import compatibility

`NativeMusicLibrary` uses the same client importer on iOS 15 and later. Required
configuration and metadata remain strict KVC writes. Three newer hints are sent
only when the receiving object exposes their setters:

- `ML3ClientImportSessionConfiguration.shouldLibraryAdd`
- `MIPAlbum.artworkSourceType`
- `MIPMediaItem.artworkSourceType`

An iOS 18.5 iPad8,9 (22F76) rejects all three keys with
`NSUnknownKeyException`. The iOS 15.5, 16 and 17.0.3 header dumps also lack
them. The original unconditional configuration write failed before the import
session was created; songs with artwork would then encounter two more failures.
Capability checks avoid encoding an OS-version guess. Available setters still
receive the existing values, including artwork source 500. Exceptions from an
available setter remain errors; this is not a blanket ignore-unknown-keys policy.

`make harness` runs `Scripts/test-music-import.sh` against the actual production
KVC boundary. It covers older objects without the hints, newer objects with them,
a missing required field, and an available setter that rejects its value.

The patched production helper was also run against the actual iOS 18.5 classes:
all three optional writes completed without exceptions and both artwork tokens
were preserved, without creating a session or changing the music database.

The 18.5 runtime inspection also matched all 31 explicitly guarded method
signatures and resolved all 11 used music-property symbols. Earlier header
checks establish interface availability, not successful import, playback or
artwork behavior. iOS 15.5 evidence does not prove every iOS 15 minor release.
The release binary audit separately checks the iOS 15.0 deployment floor and
required dynamic libraries.

Sources:

- [iOS 15.5 MusicLibrary headers](https://github.com/lechium/iPhone_OS_15.5/tree/master/System/Library/PrivateFrameworks/MusicLibrary)
- [iOS 16 MusicLibrary headers](https://github.com/qingralf/iOS16-Runtime-Headers/tree/main/PrivateFrameworks/MusicLibrary.framework)
- [iOS 17.0.3 MusicLibrary headers](https://github.com/MTACS/iOS-17-Runtime-Headers/tree/main/PrivateFrameworks/MusicLibrary.framework)
