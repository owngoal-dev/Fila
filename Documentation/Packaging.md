# Packaging verification

Use `make packages` to build and verify both Debian layouts, the TrollStore
archive and the ordinary IPA. Versions remain in `Configuration/Version.xcconfig`.

Two compositions come out of one source tree. The `Fila` target links every
backend module and is what the `.deb` and `.tipa` carry; the `FilaSandboxed`
target links `FilaCore` and `FilaLocal` alone and is what the `.ipa` carries.
`make packages` builds the full app, then the sandboxed app at the same build
number into a sibling DerivedData (`$(DERIVED_DATA)-sandboxed`), then every
wrapper; `make ipa` alone runs `make build-sandboxed`. Only the full build
bumps the build number: the sandboxed build takes the number as it stands,
so `make compile` then `make compile-sandboxed` leaves both receipts valid
and both wrappers at one number. The two DerivedData paths must differ, and
the sandboxed recipe refuses to run when they do not: both compositions are
`Fila.app`, and a copy-files phase never removes the frameworks an earlier
build left in the bundle.

`_build-ios` records a `FilaBuild.json` beside the unsigned products only after
Xcode succeeds and the source inputs remain unchanged through the build. It
hashes the app resources and binaries, daemon and archive helper; the
sandboxed build's receipt names `Fila.app` alone, and each packager asks for
the receipt of the composition it packages, so a full build cannot be handed
to the `.ipa` packager by pointing at the wrong directory. Both packagers
check this receipt before copying and again before publication. A missing receipt,
changed source, or changed product requires rebuilding. Xcode's first extraction
of changed string catalogs can require a second build; this is reported as a
changed-input failure, not silently stamped as current.

`Scripts/verify-composition.sh` runs inside every archive verification. For
the `.deb` and `.tipa` it requires each module framework embedded, linked as a
required load command and carrying the code it isolates; for the `.ipa` it
requires that no excluded framework, load command, class name or
private-framework path appears in any Mach-O of the bundle, and that the
Info.plist asks for no music library access. Every first-party framework must
carry the app's own version and build.

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
python3 Tests/test-packaging.py \
    /private/tmp/fila-deriveddata/Build/Products/Release-iphoneos \
    /private/tmp/fila-deriveddata-sandboxed/Build/Products/Release-iphoneos
```

The tests use temporary copies. They verify failed-build receipt invalidation,
stale or changed products, that the full build is refused as the sandboxed
archive, and that corrupted compression output cannot replace an already
published artifact.
