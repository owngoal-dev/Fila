#!/usr/bin/env bash
# Verify a packaged Fila .deb: control fields, payload layout, and the install
# prefix baked into the LaunchDaemon plist and maintainer scripts.

set -Eeuo pipefail

if [[ "$#" -ne 5 ]]; then
    echo "usage: $0 <deb> <package-id> <version> <architecture> <install-prefix>" >&2
    exit 64
fi

deb="$1"
package_id="$2"
version="$3"
architecture="$4"
install_prefix="$5"

[[ -f "$deb" ]] || { echo "error: missing package: $deb" >&2; exit 66; }

expect() {
    local label="$1" actual="$2" wanted="$3"
    [[ "$actual" == "$wanted" ]] || {
        echo "error: $label is '$actual', expected '$wanted'" >&2
        exit 65
    }
}

expect "Package" "$(dpkg-deb -f "$deb" Package)" "$package_id"
expect "Version" "$(dpkg-deb -f "$deb" Version)" "$version"
expect "Architecture" "$(dpkg-deb -f "$deb" Architecture)" "$architecture"

contents="$(dpkg-deb --contents "$deb")"
for payload in \
    "/Applications/Fila.app/Fila" \
    "/Applications/Fila.app/Assets.car" \
    "/Applications/Fila.app/WebUI/index.html" \
    "/Applications/Fila.app/WebUI/app.js" \
    "/Applications/Fila.app/WebUI/app.css" \
    "/Applications/Fila.app/PlugIns/FilaFileProvider.appex/FilaFileProvider" \
    "/Applications/Fila.app/PlugIns/FilaSaveAction.appex/FilaSaveAction" \
    "/usr/libexec/filad" \
    "/usr/libexec/fila-archive" \
    "/Library/LaunchDaemons/wiki.qaq.filad.plist"
do
    grep -F ".$install_prefix$payload" <<<"$contents" >/dev/null || {
        echo "error: package is missing $install_prefix$payload" >&2
        exit 65
    }
done

# Nothing may ship outside the prefix: on rootless every path lives under
# /var/jb, and a stray rootful path would install onto the sealed system.
if [[ -n "$install_prefix" ]]; then
    allowed=("./")
    walked="./"
    while IFS= read -r component; do
        walked="$walked$component/"
        allowed+=("$walked")
    done < <(tr '/' '\n' <<<"${install_prefix#/}")
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        [[ "$path" == ".$install_prefix/"* ]] && continue
        printf '%s\n' "${allowed[@]}" | grep -Fxq "$path" || {
            echo "error: package ships '$path' outside $install_prefix" >&2
            exit 65
        }
    done < <(sed -E 's/^[^ ]+[[:space:]]+[^ ]+[[:space:]]+[^ ]+[[:space:]]+[^ ]+[[:space:]]+[^ ]+[[:space:]]+//' <<<"$contents")
fi

payload_root="$(mktemp -d "${TMPDIR:-/tmp}/fila-verify.XXXXXX")"
trap 'rm -rf "$payload_root"' EXIT
dpkg-deb -x "$deb" "$payload_root"
python3 "$(dirname "$0")/verify-payload.py" "$payload_root$install_prefix/Applications/Fila.app" deb "$version" "$payload_root$install_prefix/usr/libexec/filad" "$payload_root$install_prefix/usr/libexec/fila-archive"
bash "$(dirname "$0")/verify-file-provider.sh" "$payload_root$install_prefix/Applications/Fila.app" deb
ldid -e "$payload_root$install_prefix/Applications/Fila.app/Fila" >"$payload_root/icon-entitlements.plist"
python3 "$(dirname "$0")/verify-icon-entitlements.py" "$payload_root/icon-entitlements.plist"

expect "LaunchDaemon program" \
    "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$payload_root$install_prefix/Library/LaunchDaemons/wiki.qaq.filad.plist")" \
    "$install_prefix/usr/libexec/filad"
expect "LaunchDaemon user" \
    "$(/usr/libexec/PlistBuddy -c 'Print :UserName' "$payload_root$install_prefix/Library/LaunchDaemons/wiki.qaq.filad.plist")" \
    "root"

# A missing app icon does not break the build the way a lost entitlement
# does — the asset catalog still compiles, the app still launches — so the
# only thing that catches it is Info.plist not naming what actool compiled.
expect "App icon" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$payload_root$install_prefix/Applications/Fila.app/Info.plist" 2>/dev/null || true)" \
    "AppIcon"

for script in postinst prerm; do
    body="$(dpkg-deb -I "$deb" "$script")"
    if grep -F '@PREFIX@' <<<"$body" >/dev/null; then
        echo "error: $script kept an unsubstituted install prefix" >&2
        exit 65
    fi
done

dpkg-deb -I "$deb" postinst \
    | grep -F "$install_prefix/Library/LaunchDaemons/wiki.qaq.filad.plist" >/dev/null || {
    echo "error: postinst does not bootstrap the installed LaunchDaemon plist" >&2
    exit 65
}

echo "Verified $(basename "$deb") ($architecture, prefix '${install_prefix:-/}')"
