#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 2 ]] || { echo 'usage: sign-file-provider.sh <app> <ipa|tipa|deb>' >&2; exit 64; }
app="$1"
kind="$2"
scripts="$(cd "$(dirname "$0")" && pwd -P)"
resolved="$(mktemp "${TMPDIR:-/tmp}/fila-provider-sign.XXXXXX")"
trap 'rm -f "$resolved"' EXIT

# The share action has the same standard App Group and its own bundle identity.
for entry in 'FilaFileProvider:File Provider' 'FilaSaveAction:Save action'; do
    appex="${entry%%:*}"
    label="${entry#*:}"
    bundle="$app/PlugIns/$appex.appex"
    [[ -x "$bundle/$appex" ]] || { echo "error: embedded $label is missing" >&2; exit 65; }
    case "$kind" in
        ipa) template="$scripts/../Packaging/AppGroup.entitlements" ;;
        deb|tipa) template="$scripts/../Packaging/$appex.entitlements" ;;
        *) exit 64 ;;
    esac
    python3 "$scripts/resolve-app-group-entitlements.py" "$template" "$app/Info.plist" "$resolved"
    rm -rf "$bundle/_CodeSignature"
    rm -f "$bundle/embedded.mobileprovision"
    ldid -S"$resolved" -Cadhoc "$bundle/$appex"
done
