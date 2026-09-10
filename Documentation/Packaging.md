# Packaging verification

Use `make packages` to build and verify both Debian layouts, the TrollStore
archive and the ordinary IPA. Versions remain in `Configuration/Version.xcconfig`.

## Prefixes and flavors

`FLAVOR` picks the jailbreak layout the `.deb` is built for, and the prefix is
the whole of the difference. `roothide` ships at rootful paths with an empty
prefix, because roothide's own dpkg relocates them into the randomized
bootstrap root; `rootless` ships everything under `/var/jb`, the fixed prefix
Dopamine and palera1n rootless use. The Mach-O slices are identical for both —
only the architecture label (`iphoneos-arm64e` against `iphoneos-arm64`) and
the paths differ, and the daemon works out at runtime which layout it landed
in through `InstallRoot`. No prefix is written in Swift.

`Scripts/package-deb.sh` substitutes `@PREFIX@` into the LaunchDaemon plist and
into `postinst` and `prerm` as it stages the payload. `Scripts/verify-deb.sh`
then walks the archive's whole file list and fails on any path outside the
prefix: on rootless a stray rootful path would install onto the sealed system
volume, and nothing downstream would notice. Everything else in this document
rests on that invariant.

The installed layout is the same under either prefix:

- `$prefix/Applications/Fila.app`, with `PlugIns/FilaFileProvider.appex` and
  `PlugIns/FilaSaveAction.appex` embedded in it
- `$prefix/usr/libexec/filad`
- `$prefix/usr/libexec/fila-archive`
- `$prefix/Library/LaunchDaemons/wiki.qaq.filad.plist`

`verify-deb.sh` requires each of those by name, so a dropped appex or a helper
left out of the copy is a packaging failure rather than a missing feature on
the device.

`postinst` boots the daemon: it looks `launchctl` up under the prefix and then
in `/usr/bin` and `/bin`, boots the job out if it is already loaded, bootstraps
the installed plist into `system`, and runs `uicache -p` on the installed app
so SpringBoard shows it. `prerm` reverses that on `remove` and `deconfigure` —
`bootout` and `uicache -u wiki.qaq.fila`. Both are templates, and
`verify-deb.sh` fails if either kept an unsubstituted `@PREFIX@`, and again if
`postinst` does not name the installed LaunchDaemon plist: a maintainer script
that installs cleanly and boots nothing looks exactly like a daemon that has
not spawned yet.

## Two compositions

Two compositions come out of one source tree. The `Fila` target links every
backend module and is what the `.deb` and `.tipa` carry; the `FilaSandboxed`
target links `FilaCore`, `FilaLocal` and `FilaSMB` alone and is what the `.ipa` carries.
`make packages` builds the full app, then the sandboxed app at the same build
number into a sibling DerivedData, then every wrapper; `make ipa` alone runs
`make build-sandboxed`. Only the full build
bumps the build number: the sandboxed build takes the number as it stands,
so `make compile` then `make compile-sandboxed` leaves both receipts valid
and both wrappers at one number. The two DerivedData paths must differ, and
the sandboxed recipe refuses to run when they do not: both compositions are
`Fila.app`, and a copy-files phase never removes the frameworks an earlier
build left in the bundle.

Both paths are overridable. `DERIVED_DATA` defaults to
`/private/tmp/fila-deriveddata` and `SANDBOX_DERIVED_DATA` to
`$(DERIVED_DATA)-sandboxed`, and either can be set on the command line —
parallel workers need their own, or they hand each other false greens.

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

## Two entitlement templates

`Packaging/Fila.entitlements` signs the app in the `.deb` and in the `.tipa`.
It carries the client entitlement `wiki.qaq.fila.client` that the daemon
checks before it will serve a peer, the Mach lookup for
`wiki.qaq.fila.service` and IconServices, `platform-application`,
`com.apple.private.security.no-sandbox`, the two private storage entitlements,
the InstallCoordination pair that IPA installation needs, the user-assigned
device name, and the `com.apple.security.iokit-user-client-class` list the
terminal needs to reach the GPU. `Packaging/Filad.entitlements` signs both
`filad` and `fila-archive` — the helper is the daemon's child and needs the
same platform status for AMFI to exec it.

The `.ipa` gets no entitlements template at all. The `ipa` target passes none,
and `package-ipa.sh` refuses one for that kind outright; the sandboxed app is
signed with `Packaging/AppGroup.entitlements`, which is the configured App
Group and nothing else. That contrast is the reason the split exists: the two
archives fail in opposite directions and both fail silently. A `.tipa` that
lost `platform-application` or the no-sandbox entitlement installs and then
behaves like a sandboxed app for no visible reason; an `.ipa` that kept one of
them cannot be re-signed by the user's free developer account, and the user
sees an install error about nothing they can act on. Both packagers therefore
read the entitlements back out of the signed binaries and check them in the
direction that wrapper fails in.

## What the verifiers check

`Scripts/verify-composition.sh` runs inside every *device* archive
verification — `verify-deb.sh` calls it, and `verify-ipa.sh` calls it for both
kinds. It is not on the simulator path: `Scripts/verify-simulator.sh` does not
invoke it, because a simulator build is never packaged. For
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
signature hashes, the exact entitlement templates for each wrapper, the App
Group, resources, and bootstrap layout. Invalid bundle symlinks
and installed-device `.jbroot` artifacts are rejected. These are host packaging
checks; device checks remain necessary to prove runtime behavior.

Both embedded extensions carry the App Group.
`Scripts/sign-file-provider.sh` iterates `FilaFileProvider` and
`FilaSaveAction` and signs each with the group resolved from the app's
Info.plist, and `verify-deb.sh` requires both appex executables in the payload.
The read-back is narrower than the signing: `Scripts/verify-file-provider.sh`
reads entitlements back out of the containing app and the File Provider only,
so a Save action whose group drifted from the app's would ship unnoticed. That
gap is known and not yet closed.

The remaining verifiers, one line each:

- `Scripts/verify-file-provider.sh` — the File Provider's bundle identity,
  iOS 16 floor, document group, extension point, and version agreement with
  the containing app.
- `Scripts/verify-icon-entitlements.py` — the IconServices Mach lookups, read
  back out of the signed app; without them application icons are blank and
  nothing else breaks.
- `Scripts/verify-payload.py` — the extracted device payload: architectures,
  deployment targets, entitlement templates resolved against the configured
  group, and bundle identity.
- `Scripts/verify-simulator.sh` — the linker-created simulated entitlements
  that CoreSimulator reads, and that the product is a simulator build.

## Same-version updates

`make vphone` uses a SHA-256-derived download filename and prints the full hash.
This distinguishes Safari downloads, but does not replace Sileo's package-version
identity. Same-version updates can still need removal of only the previous Fila
package from Sileo's APT cache. Close and reopen Fila after updating.

## Regression tests

Run the packaging failure regressions after a fresh build. The two arguments
are the products directories of the full and sandboxed builds — below at their
defaults, so pass the matching paths if `DERIVED_DATA` or
`SANDBOX_DERIVED_DATA` was overridden:

```sh
python3 Tests/test-packaging.py \
    /private/tmp/fila-deriveddata/Build/Products/Release-iphoneos \
    /private/tmp/fila-deriveddata-sandboxed/Build/Products/Release-iphoneos
```

The tests use temporary copies. They verify failed-build receipt invalidation,
stale or changed products, that the full build is refused as the sandboxed
archive, and that corrupted compression output cannot replace an already
published artifact.
