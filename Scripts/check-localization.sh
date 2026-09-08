#!/usr/bin/env bash
# Fail make check when a user-facing string is not something Xcode's extractor
# can see for itself.
#
# The catalogue carries no `extractionState`. That field is how a key stops
# being Xcode's problem: `manual` means "keep this even though I cannot find
# it", and a catalogue full of `manual` keys accumulates orphans invisibly —
# twenty-five of them, once. Without the field, a key that loses its last call
# site is marked `stale` on the next build and someone notices.
#
# Keeping it out costs one rule at the call site, enforced below: the extractor
# cannot see a bare literal written at an argument whose parameter type is
# `String.LocalizationValue`, which is every AlertController title, message and
# action. Wrapping the literal in the initializer makes it visible.

set -Eeuo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

error() {
    echo "error: $*" >&2
    fail=1
}

# 1. No extraction markers anywhere in any catalogue.
while IFS= read -r catalogue; do
    [ -n "$catalogue" ] || continue
    if grep -q '"extractionState"' "$catalogue"; then
        manual="$(grep -c '"extractionState" : "manual"' "$catalogue" || true)"
        stale="$(grep -c '"extractionState" : "stale"' "$catalogue" || true)"
        error "${catalogue#"$root"/} carries extraction markers ($manual manual, $stale stale).
    Every key must be one Xcode extracts by itself. A stale key is either dead —
    delete it — or its call site hides the literal from the extractor; see rule 2.
    Do not add \"extractionState\" back to silence this."
    fi
done < <(find "$root/Fila" "$root/Packages" "$root/FilaFileProvider" "$root/FilaArchive" \
    -name '*.xcstrings' -not -path '*/.build/*' 2>/dev/null || true)

# 2. No bare literal at a `String.LocalizationValue` parameter.
#
# These five labels are AlertController's localized parameters. A literal
# written straight at one of them is converted implicitly, and the extractor
# records nothing — the key never reaches the catalogue and the app ships
# English everywhere. The same labels on a plain-`String` API (UIAction,
# UIMenu) are not localized at all, which is the same bug wearing a different
# hat, so both are reported.
labels='title|message|placeholder|cancelButtonText|doneButtonText'
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    error "$hit
    A bare literal here is invisible to Xcode's string extractor.
    Write String.LocalizationValue(\"...\") for an AlertController argument,
    or String(localized: \"...\") for a plain String one."
done < <(
    grep -rlE --include='*.swift' '^import AlertController' "$root/Fila" 2>/dev/null |
        xargs grep -nE "(^|[( ])($labels): \"[^\"]" 2>/dev/null |
        sed "s|^$root/||" || true
)

if [ "$fail" -ne 0 ]; then
    exit 65
fi
echo "localization: no extraction markers, no unextractable literals"
