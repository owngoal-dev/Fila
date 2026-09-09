#!/usr/bin/env bash
# Verify a packaged Fila .tipa or .ipa: payload layout, bundle identity, the
# icon, and the entitlements read back out of the signed executable.
#
# The two archives fail in opposite directions and both fail silently. A tipa
# that lost platform-application or the no-sandbox entitlement installs and
# then behaves like a sandboxed app for no visible reason; an ipa that kept one
# of them cannot be re-signed by the user's free developer account, which
# surfaces at install time as an error about nothing the user can act on.

set -Eeuo pipefail

if [[ "$#" -ne 3 ]]; then
    echo "usage: $0 <archive> <kind> <version>" >&2
    exit 64
fi

archive="$1"
kind="$2"
version="$3"

[[ -f "$archive" ]] || { echo "error: missing archive: $archive" >&2; exit 66; }
case "$kind" in
    tipa) [[ "$archive" == *.tipa ]] || { echo "error: expected a .tipa" >&2; exit 64; } ;;
    ipa)  [[ "$archive" == *.ipa ]]  || { echo "error: expected an .ipa" >&2; exit 64; } ;;
    *) echo "error: kind must be tipa or ipa" >&2; exit 64 ;;
esac

fail() { echo "error: $*" >&2; exit 65; }

expect() {
    local label="$1" actual="$2" wanted="$3"
    [[ "$actual" == "$wanted" ]] || fail "$label is '$actual', expected '$wanted'"
}

# Neither archive carries the daemon: TrollStore installs an app and nothing
# else, and a sideloaded app has no way to run one.
contents="$(unzip -Z1 "$archive")"
grep -qE '^Payload/Fila\.app/Fila$' <<<"$contents" || fail "archive is missing Payload/Fila.app/Fila"
grep -qE 'filad|LaunchDaemons' <<<"$contents" && fail "archive ships the daemon, which nothing here can run"
while IFS= read -r path; do
    [[ -z "$path" || "$path" == Payload/* ]] || fail "archive ships '$path' outside Payload/"
done <<<"$contents"

payload_root="$(mktemp -d "${TMPDIR:-/tmp}/fila-verify-$kind.XXXXXX")"
signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/fila-verify-$kind-entitlements.XXXXXX")"
trap 'rm -rf "$payload_root"; rm -f "$signed_entitlements"' EXIT
unzip -qq "$archive" -d "$payload_root"

app="$payload_root/Payload/Fila.app"
info="$app/Info.plist"
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$info" 2>/dev/null || true; }

expect "CFBundleIdentifier" "$(plist_value CFBundleIdentifier)" "wiki.qaq.fila"
expect "CFBundleShortVersionString" "$(plist_value CFBundleShortVersionString)" "$version"

# The icon is two halves and shipping one of them shows a blank tile: actool
# writes the artwork into Assets.car, and CFBundleIconName is what points
# SpringBoard at it.
[[ -f "$app/Assets.car" ]] || fail "app bundle is missing Assets.car"
# The WebDAV server's browser page is static files the Build Web UI phase
# copies in; without them a browser gets 404 while Finder mounts fine.
for file in index.html app.js app.css; do
    [[ -f "$app/WebUI/$file" ]] || fail "app bundle is missing WebUI/$file"
done
# Nested, not top level: with GENERATE_INFOPLIST_FILE the key Xcode actually
# writes is CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName, and reading the
# top-level spelling fails on a bundle whose icon is perfectly fine.
expect "App icon" \
    "$(plist_value CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName)" \
    "AppIcon"

# Without these the sandboxed build has no way to reach a file at all: the app's
# own container never appears in Files.app, and documents open as copies.
if [[ "$kind" == ipa ]]; then
    for key in UIFileSharingEnabled LSSupportsOpeningDocumentsInPlace; do
        expect "$key" "$(plist_value "$key")" "true"
    done
fi

executable="$(plist_value CFBundleExecutable)"
ldid -e "$app/$executable" >"$signed_entitlements" 2>/dev/null || : >"$signed_entitlements"

if [[ "$kind" == tipa ]]; then
    python3 "$(dirname "$0")/verify-icon-entitlements.py" "$signed_entitlements"
    for entitlement in platform-application com.apple.private.security.no-sandbox; do
        [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$signed_entitlements" 2>/dev/null || true)" == true ]] \
            || fail "tipa executable is missing entitlement: $entitlement"
    done
else
    entitlements="$(/usr/libexec/PlistBuddy -c 'Print' "$signed_entitlements" 2>/dev/null || true)"
    for entitlement in platform-application com.apple.private.security.no-sandbox \
        com.apple.private.security.storage.AppBundles com.apple.private.security.storage.AppDataContainers \
        com.apple.private.InstallCoordination.allowed com.apple.private.InstallCoordination.uninstall \
        wiki.qaq.fila.client com.apple.security.exception.mach-lookup.global-name
    do
        grep -Fq "$entitlement" <<<"$entitlements" \
            && fail "ipa executable carries the jailbreak entitlement '$entitlement'; a free developer account cannot sign it"
    done
fi

python3 "$(dirname "$0")/verify-payload.py" "$app" "$kind" "$version"
bash "$(dirname "$0")/verify-file-provider.sh" "$app" "$kind"
# The tipa is the full composition with every module; the ipa is the
# sandboxed one, and a module that slipped into it is private API that the
# entitlement check above cannot see.
if [[ "$kind" == tipa ]]; then
    bash "$(dirname "$0")/verify-composition.sh" "$app" full
else
    bash "$(dirname "$0")/verify-composition.sh" "$app" sandboxed
fi

echo "Verified $(basename "$archive") ($kind, $(du -h "$archive" | awk '{print $1}'))"
