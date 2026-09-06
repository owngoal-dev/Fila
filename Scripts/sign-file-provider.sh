#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 2 ]] || { echo 'usage: sign-file-provider.sh <app> <ipa|tipa|deb>' >&2; exit 64; }
app="$1"
kind="$2"
scripts="$(cd "$(dirname "$0")" && pwd -P)"
provider="$app/PlugIns/FilaFileProvider.appex"
[[ -x "$provider/FilaFileProvider" ]] || { echo 'error: embedded File Provider is missing' >&2; exit 65; }
resolved="$(mktemp "${TMPDIR:-/tmp}/fila-provider-sign.XXXXXX")"
trap 'rm -f "$resolved"' EXIT
case "$kind" in
    ipa) template="$scripts/../Packaging/AppGroup.entitlements" ;;
    deb|tipa) template="$scripts/../Packaging/FilaFileProvider.entitlements" ;;
    *) exit 64 ;;
esac
python3 "$scripts/resolve-app-group-entitlements.py" "$template" "$app/Info.plist" "$resolved"
rm -rf "$provider/_CodeSignature"
rm -f "$provider/embedded.mobileprovision"
ldid -S"$resolved" -Cadhoc "$provider/FilaFileProvider"
