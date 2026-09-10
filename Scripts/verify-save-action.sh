#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 2 ]] || { echo 'usage: verify-save-action.sh <app> <ipa|tipa|deb>' >&2; exit 64; }
app="$1"
kind="$2"
action="$app/PlugIns/FilaSaveAction.appex"
fail() { echo "error: $*" >&2; exit 65; }
value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
[[ -x "$action/FilaSaveAction" ]] || fail 'embedded Save action executable is missing'
[[ "$(value "$action/Info.plist" CFBundleIdentifier)" == wiki.qaq.fila.saveaction ]] || fail 'save action bundle identity is wrong'
for key in CFBundleShortVersionString CFBundleVersion FilaAppGroupIdentifier; do
    [[ -n "$(value "$app/Info.plist" "$key")" ]] || fail "empty app $key"
    [[ "$(value "$app/Info.plist" "$key")" == "$(value "$action/Info.plist" "$key")" ]] || fail "save action $key differs from containing app"
done
group="$(value "$app/Info.plist" FilaAppGroupIdentifier)"
[[ "$group" == group.* && "$group" != *'$('* ]] || fail 'unresolved App Group identifier'
[[ "$(value "$action/Info.plist" NSExtension:NSExtensionPointIdentifier)" == com.apple.ui-services ]] || fail 'save action extension point differs'
signed="$(mktemp "${TMPDIR:-/tmp}/fila-appex-verify.XXXXXX")"
trap 'rm -f "$signed"' EXIT
ldid -e "$app/$(value "$app/Info.plist" CFBundleExecutable)" >"$signed"
python3 - "$signed" "$group" <<'PYTHON'
import plistlib, sys
with open(sys.argv[1], "rb") as stream:
    value = plistlib.load(stream)
if value.get("com.apple.security.application-groups") != [sys.argv[2]]:
    raise SystemExit("error: executable must carry exactly the configured App Group")
PYTHON
ldid -e "$action/FilaSaveAction" >"$signed"
python3 - "$signed" "$kind" "$group" <<'PYTHON'
import plistlib, sys
with open(sys.argv[1], "rb") as stream:
    value = plistlib.load(stream)
expected = {"com.apple.security.application-groups": [sys.argv[3]]}
if sys.argv[2] in ("deb", "tipa"):
    expected["application-identifier"] = "wiki.qaq.fila.saveaction"
elif sys.argv[2] != "ipa":
    raise SystemExit("error: unsupported package kind")
if value != expected:
    raise SystemExit("error: save action carries unexpected or missing entitlements")
PYTHON
