#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/fila-music-test.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun --sdk macosx clang -fobjc-arc -framework Foundation \
    -I "$root/Packages/FilaKit/Sources/CFilaMusicLibrary/include" \
    "$root/Tests/test-music-import.m" -o "$temporary/music-import-tests"
"$temporary/music-import-tests"
