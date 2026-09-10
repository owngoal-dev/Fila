#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "$#" -ne 13 ]]; then
    echo "usage: $0 <app> <daemon> <archive-helper> <control> <app-entitlements> <daemon-entitlements> <launch-plist> <output-deb> <package-id> <version> <architecture> <flavor> <install-prefix>" >&2
    exit 64
fi

app_bundle="$1"
scripts="$(cd "$(dirname "$0")" && pwd -P)"
build_identity="$(python3 "$scripts/build-package-inputs.py" verify "$(dirname "$app_bundle")")"
daemon_binary="$2"
helper_binary="$3"
[[ "$app_bundle" -ef "$(dirname "$app_bundle")/Fila.app" && "$daemon_binary" -ef "$(dirname "$app_bundle")/filad" && "$helper_binary" -ef "$(dirname "$app_bundle")/fila-archive" ]] || {
    echo "error: app, daemon and helper must come from the same verified build" >&2
    exit 65
}
action_bundle="$app_bundle/PlugIns/FilaSaveAction.appex"
action_entitlements="$(cd "$(dirname "$0")/../Packaging" && pwd -P)/FilaSaveAction.entitlements"
control_template="$4"
app_entitlements="$5"
daemon_entitlements="$6"
launch_plist="$7"
output_deb="$8"
package_id="$9"
version="${10}"
architecture="${11}"
flavor="${12}"
install_prefix="${13}"

[[ -d "$app_bundle" && -f "$app_bundle/Info.plist" ]] || { echo "error: incomplete app bundle" >&2; exit 66; }
[[ -d "$action_bundle" && -x "$action_bundle/FilaSaveAction" && -f "$action_bundle/Info.plist" ]] || { echo "error: embedded Save action is missing" >&2; exit 66; }
[[ -x "$daemon_binary" ]] || { echo "error: daemon binary is missing" >&2; exit 66; }
[[ -x "$helper_binary" ]] || { echo "error: archive helper binary is missing" >&2; exit 66; }
for input in "$control_template" "$app_entitlements" "$daemon_entitlements" "$launch_plist" "$action_entitlements"; do
    [[ -f "$input" ]] || { echo "error: missing packaging input: $input" >&2; exit 66; }
done
[[ "$output_deb" == *.deb ]] || { echo "error: output must end in .deb" >&2; exit 64; }
[[ "$package_id" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || { echo "error: invalid package id" >&2; exit 64; }
[[ "$version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] || { echo "error: invalid version" >&2; exit 64; }
[[ "$architecture" =~ ^[A-Za-z0-9][A-Za-z0-9-]+$ ]] || { echo "error: invalid architecture" >&2; exit 64; }
case "$flavor" in
    roothide) [[ -z "$install_prefix" ]] || { echo "error: roothide packages install at rootful paths" >&2; exit 64; } ;;
    rootless) [[ "$install_prefix" == /var/jb ]] || { echo "error: rootless packages install under /var/jb" >&2; exit 64; } ;;
    *) echo "error: flavor must be roothide or rootless" >&2; exit 64 ;;
esac

case "$architecture:$install_prefix" in
iphoneos-arm64:/var/jb | iphoneos-arm64e:) ;;
*) echo "error: architecture and install prefix name different bootstrap layouts" >&2; exit 64 ;;
esac

# These native daemons make authorization/path decisions on physical paths.
# Rewriting their libc imports independently would change that contract.
native_dependencies="$(otool -L "$daemon_binary" "$helper_binary")"
if grep -q 'libvroot' <<<"$native_dependencies"; then
    echo "error: native daemon uses physical paths; unexpected vroot dependency" >&2
    exit 65
fi

app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_bundle/Info.plist")"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Info.plist")"
[[ "$bundle_identifier" == wiki.qaq.fila && -x "$app_bundle/$app_executable" ]] || {
    echo "error: unexpected app identity" >&2
    exit 65
}

# The package version comes from Configuration/Version.xcconfig, which is also
# what the app was built with — refuse to ship a .deb that disagrees.
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Info.plist")"
[[ "$app_version" == "$version" ]] || {
    echo "error: app version '$app_version' does not match package version '$version'" >&2
    exit 65
}

output_name="$(basename "$output_deb")"
mkdir -p "$(dirname "$output_deb")"
output_directory="$(cd "$(dirname "$output_deb")" && pwd -P)"
output_deb="$output_directory/$output_name"
staging="$(mktemp -d "${TMPDIR:-/tmp}/fila-deb.XXXXXX")"
publication="$(mktemp -d "$output_directory/.fila-package.XXXXXX")"
temporary_deb="$publication/$output_name"
app_signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/fila-app-entitlements.XXXXXX")"
daemon_signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/fila-daemon-entitlements.XXXXXX")"
trap 'rm -rf "$staging" "$publication"; rm -f "$temporary_deb" "$app_signed_entitlements" "$daemon_signed_entitlements"' EXIT
chmod 0755 "$staging"

debian="$staging/DEBIAN"
installed_app="$staging$install_prefix/Applications/Fila.app"
installed_daemon="$staging$install_prefix/usr/libexec/filad"
installed_helper="$staging$install_prefix/usr/libexec/fila-archive"
installed_plist="$staging$install_prefix/Library/LaunchDaemons/wiki.qaq.filad.plist"
mkdir -p "$debian" "$(dirname "$installed_app")" "$(dirname "$installed_daemon")" "$(dirname "$installed_plist")"
/usr/bin/ditto "$app_bundle" "$installed_app"
/usr/bin/ditto "$daemon_binary" "$installed_daemon"
/usr/bin/ditto "$helper_binary" "$installed_helper"
bash "$(dirname "$0")/sign-extensions.sh" "$installed_app" deb
python3 "$(dirname "$0")/resolve-app-group-entitlements.py" "$app_entitlements" "$installed_app/Info.plist" "$staging/app-entitlements.plist"
app_entitlements="$staging/app-entitlements.plist"
sed -e "s|@PREFIX@|$install_prefix|g" "$launch_plist" >"$installed_plist"
rm -rf "$installed_app/_CodeSignature"
rm -f "$installed_app/embedded.mobileprovision"
chmod 0755 "$installed_daemon" "$installed_helper"
chmod 0644 "$installed_plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$installed_plist")" == "$install_prefix/usr/libexec/filad" ]] || {
    echo "error: launch daemon plist does not point at the installed daemon" >&2
    exit 65
}

bash "$(dirname "$0")/sign-frameworks.sh" "$installed_app"
ldid -S"$app_entitlements" -Cadhoc "$installed_app/$app_executable"
# The helper is signed like the daemon: it is the daemon's child, runs as root
# and writes wherever the job says, so it needs the same freedom from the
# sandbox and the same platform status for AMFI to let it exec.
ldid -S"$daemon_entitlements" -Cadhoc "$installed_daemon"
ldid -S"$daemon_entitlements" -Cadhoc "$installed_helper"
ldid -e "$installed_app/$app_executable" >"$app_signed_entitlements"
ldid -e "$installed_daemon" >"$daemon_signed_entitlements"
helper_signed_entitlements="$staging/helper-entitlements.plist"
ldid -e "$installed_helper" >"$helper_signed_entitlements"
bash "$(dirname "$0")/verify-save-action.sh" "$installed_app" deb
rm -f "$staging/app-entitlements.plist"

require_true() {
    local plist="$1"
    local key="$2"
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)" == true ]] || {
        echo "error: signed executable is missing entitlement: $key" >&2
        exit 65
    }
}

# The daemon admits a client only if the kernel says it carries these, so a
# build that lost one would ship an app the daemon silently refuses to serve.
for entitlement in platform-application com.apple.private.security.no-sandbox com.apple.private.security.storage.AppBundles com.apple.private.security.storage.AppDataContainers wiki.qaq.fila.client com.apple.private.InstallCoordination.allowed com.apple.private.InstallCoordination.uninstall; do
    require_true "$app_signed_entitlements" "$entitlement"
done
python3 "$(dirname "$0")/verify-icon-entitlements.py" "$app_signed_entitlements"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.exception.mach-lookup.global-name:0' "$app_signed_entitlements")" == wiki.qaq.fila.service ]] || {
    echo "error: app is missing the daemon mach lookup entitlement" >&2
    exit 65
}
for entitlement in platform-application com.apple.private.security.no-sandbox com.apple.private.security.storage.AppBundles com.apple.private.security.storage.AppDataContainers; do
    require_true "$daemon_signed_entitlements" "$entitlement"
    require_true "$helper_signed_entitlements" "$entitlement"
done
rm -f "$helper_signed_entitlements"

# DEBIAN is still empty at this point, so this measures only the payload.
installed_size="$(du -sk "$staging" | awk '{print $1}')"
sed \
    -e "s/@PACKAGE_ID@/$package_id/g" \
    -e "s/@VERSION@/$version/g" \
    -e "s/@ARCHITECTURE@/$architecture/g" \
    -e "s/@INSTALLED_SIZE@/$installed_size/g" \
    -e "s/@FLAVOR@/$flavor/g" \
    "$control_template" >"$debian/control"

packaging_root="$(cd "$(dirname "$control_template")/.." && pwd -P)"
for script in postinst prerm; do
    sed -e "s|@PREFIX@|$install_prefix|g" "$packaging_root/DEBIAN/$script" >"$debian/$script"
done
chmod 0644 "$debian/control"
chmod 0755 "$debian/postinst" "$debian/prerm"

dpkg-deb --root-owner-group -Zzstd -b "$staging" "$temporary_deb"
bash "$scripts/verify-deb.sh" "$temporary_deb" "$package_id" "$version" "$architecture" "$install_prefix"
[[ "$build_identity" == "$(python3 "$scripts/build-package-inputs.py" verify "$(dirname "$app_bundle")")" ]] || {
    echo "error: build changed during packaging; package the new build again" >&2
    exit 65
}
python3 -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' "$temporary_deb" "$output_deb"
echo "Packaged Fila ($flavor): $output_deb"
shasum -a 256 "$output_deb"
