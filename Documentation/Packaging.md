# Packaging verification

Use `make packages` to build and verify both Debian layouts, the TrollStore
archive and the ordinary IPA. Versions remain in `Configuration/Version.xcconfig`.

`_build-ios` records a `FilaBuild.json` beside the unsigned products only after
Xcode succeeds and the source inputs remain unchanged through the build. It
hashes the app resources and binaries, daemon and archive helper. Both packagers
check this receipt before copying and again before publication. A missing receipt,
changed source, or changed product requires rebuilding. Xcode's first extraction
of changed string catalogs can require a second build; this is reported as a
changed-input failure, not silently stamped as current.

Every entry point, including `_package-deb` and `make vphone`, verifies the final
archive before atomically replacing its destination. An unsuccessful verification
leaves the previous artifact intact and exits with failure. The verifier checks
layout, bundle/build identity, iOS device slices and deployment targets, code
signature hashes, the exact entitlement templates for each wrapper, the File
Provider's App Group, resources, and bootstrap layout. Invalid bundle symlinks
and installed-device `.jbroot` artifacts are rejected. These are host packaging
checks; device checks remain necessary to prove runtime behavior.

`make vphone` uses a SHA-256-derived download filename and prints the full hash.
This distinguishes Safari downloads, but does not replace Sileo's package-version
identity. Same-version updates can still need removal of only the previous Fila
package from Sileo's APT cache. Close and reopen Fila after updating.

Run the packaging failure regressions after a fresh build:

```sh
python3 Tests/test-packaging.py /private/tmp/fila-deriveddata/Build/Products/Release-iphoneos
```

The tests use temporary copies. They verify failed-build receipt invalidation,
stale or changed products, and that corrupted compression output cannot replace
an already published artifact.
