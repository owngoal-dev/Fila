#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 2 ]] || { echo 'usage: verify-file-provider.sh <app> <ipa|tipa|deb>' >&2; exit 64; }
app="$1"
kind="$2"
provider="$app/PlugIns/FilaFileProvider.appex"
fail() { echo "error: $*" >&2; exit 65; }
value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
[[ -x "$provider/FilaFileProvider" ]] || fail 'embedded File Provider executable is missing'
# The replicated API is iOS 16; a 15 device must not load the extension at all.
[[ "$(value "$provider/Info.plist" MinimumOSVersion)" == 16.0 ]] || fail 'provider MinimumOSVersion must be 16.0'
[[ "$(value "$provider/Info.plist" CFBundleIdentifier)" == wiki.qaq.fila.fileprovider ]] || fail 'provider bundle identity is wrong'
for key in CFBundleShortVersionString CFBundleVersion FilaAppGroupIdentifier; do
    [[ -n "$(value "$app/Info.plist" "$key")" ]] || fail "empty app $key"
    [[ "$(value "$app/Info.plist" "$key")" == "$(value "$provider/Info.plist" "$key")" ]] || fail "provider $key differs from containing app"
done
group="$(value "$app/Info.plist" FilaAppGroupIdentifier)"
[[ "$group" == group.* && "$group" != *'$('* ]] || fail 'unresolved App Group identifier'
[[ "$(value "$provider/Info.plist" NSExtension:NSExtensionFileProviderDocumentGroup)" == "$group" ]] || fail 'provider document group differs'
[[ "$(value "$provider/Info.plist" NSExtension:NSExtensionPointIdentifier)" == com.apple.fileprovider-nonui ]] || fail 'provider extension point differs'
signed="$(mktemp "${TMPDIR:-/tmp}/fila-provider-verify.XXXXXX")"
trap 'rm -f "$signed"' EXIT
for executable in "$app/$(value "$app/Info.plist" CFBundleExecutable)" "$provider/FilaFileProvider"; do
    ldid -e "$executable" >"$signed"
    python3 - "$signed" "$group" <<'PYTHON'
import plistlib, sys
with open(sys.argv[1], "rb") as stream:
    value = plistlib.load(stream)
if value.get("com.apple.security.application-groups") != [sys.argv[2]]:
    raise SystemExit("error: executable must carry exactly the configured App Group")
PYTHON
done
python3 - "$signed" "$kind" "$group" <<'PYTHON'
import plistlib, sys
with open(sys.argv[1], "rb") as stream:
    value = plistlib.load(stream)
expected = {"com.apple.security.application-groups": [sys.argv[3]]}
if sys.argv[2] in ("deb", "tipa"):
    expected["application-identifier"] = "wiki.qaq.fila.fileprovider"
elif sys.argv[2] != "ipa":
    raise SystemExit("error: unsupported package kind")
if value != expected:
    raise SystemExit("error: provider carries unexpected or missing entitlements")
PYTHON
