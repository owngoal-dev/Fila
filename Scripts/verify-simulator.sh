#!/usr/bin/env bash
# CoreSimulator reads the linker-created simulated entitlements, not merely
# an ad-hoc code signature added after an unsigned build.
set -Eeuo pipefail
[[ $# == 1 ]] || { echo 'usage: verify-simulator.sh <Fila.app>' >&2; exit 64; }
app="$1"
provider="$app/PlugIns/FilaFileProvider.appex"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$app/Info.plist")" == iPhoneSimulator ]] || {
    echo 'error: simulator verification refuses a device product' >&2
    exit 65
}
[[ -x "$provider/FilaFileProvider" ]] || { echo 'error: embedded File Provider is missing' >&2; exit 65; }
group="$(/usr/libexec/PlistBuddy -c 'Print :FilaAppGroupIdentifier' "$app/Info.plist")"
readback="$(mktemp "${TMPDIR:-/tmp}/fila-simulator-readback.XXXXXX")"
sections="$(mktemp "${TMPDIR:-/tmp}/fila-simulator-sections.XXXXXX")"
trap 'rm -f "$readback" "$sections"' EXIT
for bundle in "$provider" "$app"; do
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Info.plist")"
    /usr/bin/codesign --display --xml --entitlements - "$bundle" >"$readback"
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Info.plist")"
    xcrun otool -s __TEXT __entitlements "$bundle/$executable" >"$sections"
    python3 - "$group" "$identifier" "$readback" "$sections" <<'PYTHON'
import plistlib, re, sys
from pathlib import Path

group, bundle_id, signature_path, sections_path = sys.argv[1:]
if not re.fullmatch(r"group\.[A-Za-z0-9.-]+", group):
    raise SystemExit("error: unresolved simulator App Group")

def reject_private(value):
    if any(key.startswith("com.apple.private.") or key in ("platform-application", "wiki.qaq.fila.client") for key in value):
        raise SystemExit("error: simulator product must not carry jailbreak entitlements")

# Native simulator signatures can legitimately contain an empty dictionary;
# CoreSimulator takes runtime permissions from the section checked below.
blob = Path(signature_path).read_bytes()
if blob.strip():
    signature = plistlib.loads(blob)
    reject_private(signature)
    if "com.apple.security.application-groups" in signature and signature["com.apple.security.application-groups"] != [group]:
        raise SystemExit("error: signature and simulated App Group disagree")

# otool prints x86 slices as bytes and ARM slices as little-endian words.
# Validate every slice, not just whichever architecture happened to be first.
sections = []
current = None
for line in Path(sections_path).read_text().splitlines():
    if line.startswith("Contents of (__TEXT,__entitlements) section"):
        if current is not None:
            sections.append(current)
        current = bytearray()
        continue
    match = re.fullmatch(r"[0-9a-fA-F]+\s+((?:(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{2})\s*)+)", line)
    if current is not None and match:
        for word in match.group(1).split():
            current.extend(int(word, 16).to_bytes(len(word) // 2, "little"))
if current is not None:
    sections.append(current)
if not sections:
    raise SystemExit("error: missing simulated entitlement section; rebuild with native Xcode ad-hoc signing enabled")
for raw in sections:
    value = plistlib.loads(bytes(raw).rstrip(b"\0"))
    reject_private(value)
    if value.get("com.apple.security.application-groups") != [group]:
        raise SystemExit("error: simulated entitlements lack the exact configured App Group")
    identity = value.get("application-identifier", "")
    if identity != bundle_id and not identity.endswith("." + bundle_id):
        raise SystemExit("error: simulated application identity does not match its bundle")
PYTHON
done
/usr/bin/codesign --verify --deep --strict "$app"
