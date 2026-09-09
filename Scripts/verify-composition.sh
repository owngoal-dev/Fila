#!/usr/bin/env bash
# Verify which backend modules a packaged Fila.app actually carries.
#
#   full       The .deb and the .tipa: every module framework is embedded,
#              linked as a startup dependency of the executable, and carries
#              the markers of the code it exists to isolate.
#   sandboxed  The .ipa: the privileged, applications and music modules are
#              absent from the bundle, from every load command, and from the
#              bytes of every Mach-O in it — no framework, no symbol, no
#              private-framework path, no selector string.
#
# The two compositions are two app targets over the same sources, so nothing
# in the source tree says which one a bundle is. Only the bundle does, which
# is why this reads the product rather than the project. A module that is
# hidden by the registry at runtime is still shipped, and "shipped" is what
# an App Store review or a free developer account's re-signing sees.
set -Eeuo pipefail
[[ $# == 2 ]] || { echo 'usage: verify-composition.sh <Fila.app> <full|sandboxed>' >&2; exit 64; }
app="$1"
composition="$2"
fail() { echo "error: $*" >&2; exit 65; }
[[ -d "$app" && -x "$app/Fila" ]] || fail "not an app bundle: $app"

shared=(FilaCore FilaLocal FilaSMB)
excluded=(FilaPrivileged FilaApplications FilaMusicLibrary)
# One string per excluded module that only that module's code contains:
# the XPC link's class, the LaunchServices private class the catalogue
# reads, and the MediaLibrary bridge. Checked as bytes, not as symbols,
# because a stripped Release binary keeps its selector and class-name
# strings and drops its symbol table.
markers=(
    FilaPrivilegedModule DaemonLink
    FilaApplicationsModule LSApplicationWorkspace MobileInstallation.framework IXAppInstallCoordinator
    FilaMusicLibraryModule NativeMusicLibrary MediaLibrary.sqlitedb
)

# Every Mach-O the app would map: the executable, each embedded framework
# and each extension, plus the libraries under their own Frameworks.
machos() {
    echo "$app/Fila"
    for framework in "$app"/Frameworks/*.framework; do
        [[ -d "$framework" ]] && echo "$framework/$(basename "$framework" .framework)"
    done
    for library in "$app"/Frameworks/*.dylib; do
        [[ -f "$library" ]] && echo "$library"
    done
    for appex in "$app"/PlugIns/*.appex; do
        [[ -d "$appex" ]] || continue
        echo "$appex/$(basename "$appex" .appex)"
        for framework in "$appex"/Frameworks/*.framework; do
            [[ -d "$framework" ]] && echo "$framework/$(basename "$framework" .framework)"
        done
    done
}

# A first-party framework must carry the app's own version and build: the
# registry refuses a mismatch at launch, silently, and the packaging is
# where that mismatch is a mistake someone can see.
version() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist" 2>/dev/null || true; }
app_version="$(version "$app" CFBundleShortVersionString)"
app_build="$(version "$app" CFBundleVersion)"
check_framework() {
    local name="$1" framework="$app/Frameworks/$1.framework"
    [[ -f "$framework/$name" ]] || fail "$name.framework is not embedded"
    [[ "$(version "$framework" CFBundleShortVersionString)" == "$app_version" ]] || fail "$name.framework version differs from the app"
    [[ "$(version "$framework" CFBundleVersion)" == "$app_build" ]] || fail "$name.framework build differs from the app"
    [[ "$name" == FilaCore ]] && return
    [[ -f "$framework/FilaBackendModule.plist" ]] || fail "$name.framework carries no module manifest"
    # A startup dependency, non-weak: the module registers itself before
    # main, so it must be mapped by dyld and never left to a dlopen.
    otool -L "$app/Fila" | grep -F "$name.framework/$name" | grep -qv 'weak' \
        || fail "Fila does not link $name.framework as a required load command"
}

for name in "${shared[@]}"; do check_framework "$name"; done

case "$composition" in
    full)
        for name in "${excluded[@]}"; do check_framework "$name"; done
        # Each module still carries what it isolates; a module that lost
        # its private code would register nothing and hide the loss.
        grep -aFq DaemonLink "$app/Frameworks/FilaPrivileged.framework/FilaPrivileged" || fail "FilaPrivileged carries no daemon link"
        grep -aFq LSApplicationWorkspace "$app/Frameworks/FilaApplications.framework/FilaApplications" || fail "FilaApplications carries no LaunchServices catalogue"
        grep -aFq NativeMusicLibrary "$app/Frameworks/FilaMusicLibrary.framework/FilaMusicLibrary" || fail "FilaMusicLibrary carries no MediaLibrary bridge"
        ;;
    sandboxed)
        # Nothing named after an excluded module anywhere in the bundle:
        # not a framework, not a resource bundle, not a stray catalogue.
        for name in "${excluded[@]}"; do
            # `-quit`, not `| head -1`: under pipefail a `find` still writing
            # when `head` closes dies of SIGPIPE and takes the message with it.
            found="$(find "$app" -iname "*$name*" -print -quit)"
            [[ -z "$found" ]] || fail "sandboxed app ships $found"
        done
        while IFS= read -r macho; do
            [[ -f "$macho" ]] || continue
            for name in "${excluded[@]}"; do
                otool -L "$macho" | grep -qF "$name.framework" && fail "$macho links $name.framework"
            done
            for marker in "${markers[@]}"; do
                grep -aFq "$marker" "$macho" && fail "$macho contains '$marker', which belongs to an excluded module"
            done
        done < <(machos)
        # The music usage description is the one Info.plist key the excluded
        # features own; a sandboxed app that asks for music access has no
        # module to use it.
        [[ -z "$(version "$app" NSAppleMusicUsageDescription)" ]] || fail "sandboxed Info.plist asks for music library access"
        ;;
    *) echo 'error: composition must be full or sandboxed' >&2; exit 64 ;;
esac

echo "Verified $composition composition of $(basename "$app")"
