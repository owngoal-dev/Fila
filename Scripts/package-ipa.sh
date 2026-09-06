#!/usr/bin/env bash
# Package Fila.app on its own — no filad, no LaunchDaemon — as the Payload/
# archive both TrollStore and the sideloading tools expect.
#
#   tipa  TrollStore. Ad-hoc signed with Packaging/Fila.entitlements, exactly
#         as the .deb path signs it: TrollStore installs a permanently-signed
#         app and applies the entitlements it finds embedded. There is no root
#         daemon and no launchd job, so filad is not in this payload and the
#         app falls back to doing the work in-process.
#   ipa   AltStore / SideStore / Sideloadly. Ad-hoc signed with only the configured App Group entitlement
#         and no jailbreak entitlements — the user's own certificate is applied at install time, and
#         the signer must provision the shared group for app and extension.
#         Override APP_GROUP_IDENTIFIER in Developer*.xcconfig as needed.

set -Eeuo pipefail

if [[ "$#" -lt 4 ]]; then
    echo "usage: $0 <app> <kind> <output-archive> <version> [app-entitlements]" >&2
    exit 64
fi

app_bundle="$1"
scripts="$(cd "$(dirname "$0")" && pwd -P)"
build_identity="$(python3 "$scripts/build-package-inputs.py" verify "$(dirname "$app_bundle")")"
[[ "$app_bundle" -ef "$(dirname "$app_bundle")/Fila.app" ]] || { echo "error: app differs from the verified build" >&2; exit 65; }
kind="$2"
output_archive="$3"
version="$4"
app_entitlements="${5:-}"

case "$kind" in
    tipa)
        [[ "$output_archive" == *.tipa ]] || { echo "error: tipa output must end in .tipa" >&2; exit 64; }
        [[ -f "$app_entitlements" ]] || { echo "error: the tipa needs the app entitlements" >&2; exit 66; }
        ;;
    ipa)
        [[ "$output_archive" == *.ipa ]] || { echo "error: ipa output must end in .ipa" >&2; exit 64; }
        [[ -z "$app_entitlements" ]] || { echo "error: the sideloaded ipa carries no entitlements" >&2; exit 64; }
        ;;
    *) echo "error: kind must be tipa or ipa" >&2; exit 64 ;;
esac

[[ -d "$app_bundle" && -f "$app_bundle/Info.plist" ]] || { echo "error: incomplete app bundle" >&2; exit 66; }
[[ "$version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] || { echo "error: invalid version" >&2; exit 64; }

app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_bundle/Info.plist")"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Info.plist")"
[[ "$bundle_identifier" == wiki.qaq.fila && -x "$app_bundle/$app_executable" ]] || {
    echo "error: unexpected app identity" >&2
    exit 65
}

# Same rule as the .deb: the archive version comes from Version.xcconfig, which
# is also what the app was built with — refuse to ship a disagreement.
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Info.plist")"
[[ "$app_version" == "$version" ]] || {
    echo "error: app version '$app_version' does not match archive version '$version'" >&2
    exit 65
}

output_name="$(basename "$output_archive")"
mkdir -p "$(dirname "$output_archive")"
output_directory="$(cd "$(dirname "$output_archive")" && pwd -P)"
output_archive="$output_directory/$output_name"
staging="$(mktemp -d "${TMPDIR:-/tmp}/fila-$kind.XXXXXX")"
publication="$(mktemp -d "$output_directory/.fila-package.XXXXXX")"
temporary_archive="$publication/$output_name"
signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/fila-$kind-entitlements.XXXXXX")"
trap 'rm -rf "$staging" "$publication"; rm -f "$temporary_archive" "$signed_entitlements"' EXIT
chmod 0755 "$staging"

payload_app="$staging/Payload/Fila.app"
mkdir -p "$(dirname "$payload_app")"
/usr/bin/ditto "$app_bundle" "$payload_app"
rm -rf "$payload_app/_CodeSignature"
rm -f "$payload_app/embedded.mobileprovision"

bash "$(dirname "$0")/sign-file-provider.sh" "$payload_app" "$kind"
if [[ "$kind" == tipa ]]; then
    template="$app_entitlements"
else
    template="$(dirname "$0")/../Packaging/AppGroup.entitlements"
fi
python3 "$(dirname "$0")/resolve-app-group-entitlements.py" "$template" "$payload_app/Info.plist" "$staging/app-entitlements.plist"
bash "$(dirname "$0")/sign-frameworks.sh" "$payload_app"
ldid -S"$staging/app-entitlements.plist" -Cadhoc "$payload_app/$app_executable"
bash "$(dirname "$0")/verify-file-provider.sh" "$payload_app" "$kind"
ldid -e "$payload_app/$app_executable" >"$signed_entitlements"

# Read the entitlements back out of the signed binary, the same reason
# package-deb.sh does: losing one does not break the build, it breaks the app
# somewhere that looks nothing like the cause. The failure runs in opposite
# directions for the two archives — the tipa is broken by an entitlement that
# went missing, the ipa by one that stayed.
entitlement_is_true() {
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$1" "$signed_entitlements" 2>/dev/null || true)" == true ]]
}

if [[ "$kind" == tipa ]]; then
    python3 "$(dirname "$0")/verify-icon-entitlements.py" "$signed_entitlements"
    for entitlement in platform-application com.apple.private.security.no-sandbox; do
        entitlement_is_true "$entitlement" || {
            echo "error: signed executable is missing entitlement: $entitlement" >&2
            exit 65
        }
    done
else
    if [[ -s "$signed_entitlements" ]] \
        && /usr/libexec/PlistBuddy -c 'Print' "$signed_entitlements" 2>/dev/null | grep -qE 'platform-application|com\.apple\.private|wiki\.qaq\.fila\.client|mach-lookup'; then
        echo "error: the sideloaded ipa must carry no jailbreak entitlements" >&2
        exit 65
    fi
fi

(cd "$staging" && zip -qry "$temporary_archive" Payload)
bash "$scripts/verify-ipa.sh" "$temporary_archive" "$kind" "$version"
[[ "$build_identity" == "$(python3 "$scripts/build-package-inputs.py" verify "$(dirname "$app_bundle")")" ]] || {
    echo "error: build changed during packaging; package the new build again" >&2
    exit 65
}
python3 -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' "$temporary_archive" "$output_archive"
echo "Packaged Fila ($kind): $output_archive"
shasum -a 256 "$output_archive"
