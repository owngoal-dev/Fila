#!/usr/bin/env bash
# Fail make check when a call site bypasses SnapKit, Then, AlertController, or
# Toast. The libraries are app-side; the daemon and the file layer must stay
# free of them, and the UI must not grow a second way to do the same job.

set -Eeuo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

error() {
    echo "error: $*" >&2
    fail=1
}

# rg is the same search the rest of the repo already assumes; fall back to
# grep -R so a machine without ripgrep still gates a release.
search() {
    local pattern="$1"
    shift
    if command -v rg >/dev/null; then
        rg -n --glob '*.swift' -e "$pattern" "$@" || true
    else
        grep -Rn --include='*.swift' -E "$pattern" "$@" || true
    fi
}

ui_roots=(
    "$root/Fila"
    "$root/Packages/FilaKit/Sources/FilaTerminal"
)

# The floor the app promises. Two checks below are relative to it, and both stop
# applying once it rises past the OS that caused them.
minimum_ios="$(sed -n 's/^IPHONEOS_DEPLOYMENT_TARGET = \([0-9.]*\).*/\1/p' "$root/Configuration/Base.xcconfig")"
minimum_ios_major="${minimum_ios%%.*}"
: "${minimum_ios:?Configuration/Base.xcconfig has no IPHONEOS_DEPLOYMENT_TARGET}"

layout_hits="$(search 'NSLayoutConstraint|translatesAutoresizingMaskIntoConstraints|[A-Za-z]+Anchor\.constraint\(' "${ui_roots[@]}")"
if [[ -n "$layout_hits" ]]; then
    error "layout must use SnapKit; found NSLayoutConstraint / autoresizing-mask / anchor.constraint:"
    echo "$layout_hits" >&2
fi

alert_hits="$(search 'UIAlertController|UIAlertAction' "${ui_roots[@]}")"
if [[ -n "$alert_hits" ]]; then
    error "alerts must use AlertController; found UIAlertController / UIAlertAction:"
    echo "$alert_hits" >&2
fi

indicator_hits="$(search 'import SPIndicator|SPIndicatorView' "${ui_roots[@]}" \
    | grep -v 'Fila/Interface/Feedback/Toast.swift' || true)"
if [[ -n "$indicator_hits" ]]; then
    error "toasts must go through Toast; found SPIndicator outside Toast.swift:"
    echo "$indicator_hits" >&2
fi

# A settings-style key/value row is one line (`valueCell`, value trailing).
# `subtitleCell` stacks two lines and is for content lists only — a file row
# with its size, a plist key with its summary — and those files are named here.
subtitle_hits="$(search 'subtitleCell\(\)' "${ui_roots[@]}" \
    | grep -v -E 'Clipboard/ClipboardViewController\.swift|Viewer/Archive/ArchiveBrowserViewController\.swift|Viewer/Plist/PropertyListEditorViewController\.swift|Viewer/Shared/KeyValueListViewController\.swift|Applications/AppDetailViewController\.swift|Settings/FileSharingViewController\.swift' || true)"
if [[ -n "$subtitle_hits" ]]; then
    error "key/value rows are one line: use UIListContentConfiguration.valueCell(), or add a content list to the allowlist in $0:"
    echo "$subtitle_hits" >&2
fi

# Every alert card carries a message under its title. An empty or missing
# `message:` is a bare title over a text field, which reads as unfinished.
alert_message_hits="$(perl -0777 -ne '
    while (/\bAlert(?:Input)?ViewController\(([^{]*?)\)\s*\{/sg) {
        my ($args, $offset) = ($1, $-[0]);
        next if $args =~ /\bmessage:\s*+(?!"")/;
        # The progress card uses the public custom-content initializer because
        # the progress convenience API exposes no background/cancel actions.
        # Allow only that call site, and require its visible message assignment
        # to retain a non-empty fallback while the job is preparing.
        next if $ARGV =~ m{/Fila/Interface/Transfers/OperationCoverViewController\.swift$}
            && $args =~ /^contentViewController:\s*content\b/
            && /subtitleLabel\.text\s*=\s*operation\.subtitle\.isEmpty\s*\?\s*String\(localized:\s*"Preparing…"\)\s*:\s*operation\.subtitle/;
        # Permanent deletion uses the public custom-content API for a red
        # action without changing the global accent.
        next if $ARGV =~ m{/Fila/Interface/Feedback/PermanentDeleteConfirmation\.swift$}
            && $args =~ /^contentViewController:\s*content\b/;
        my $line = 1 + (substr($_, 0, $offset) =~ tr/\n//);
        print "$ARGV:$line: $&\n";
    }' $(find "${ui_roots[@]}" -name '*.swift'))"
if [[ -n "$alert_message_hits" ]]; then
    error "every AlertViewController / AlertInputViewController needs a non-empty message:"
    echo "$alert_message_hits" >&2
fi

# Escape dismissal is not a visible action. Inspect the complete context
# closure, including nested action handlers: mutating buttons alone do not
# provide a way to cancel, even when they follow allowSimpleDispose().
empty_alert_hits="$(perl -0777 -ne '
    while (/\{\s*(?:\[[^\]]*\]\s*)?context\s+in(?<body>(?:[^{}"]+|"(?:\\.|[^"\\])*"|\{(?&body)\})*)\}/sg) {
        my $body = $+{body};
        my $offset = $-[0];
        next unless $body =~ /context\.allowSimpleDispose\(\)/;
        next if $body =~ /context\.addAction\(\s*title:\s*"(?:Cancel|Close|OK)"/s;
        my $line = 1 + (substr($_, 0, $offset) =~ tr/\n//);
        print "$ARGV:$line: allowSimpleDispose needs a visible Cancel/Close/OK action\n";
    }' $(find "${ui_roots[@]}" -name '*.swift'))"
if [[ -n "$empty_alert_hits" ]]; then
    error "alert cards need a visible dismissal button:"
    echo "$empty_alert_hits" >&2
fi

delete_icon_hits="$(search '"trash\.slash"' "${ui_roots[@]}")"
if [[ -n "$delete_icon_hits" ]]; then
    error "deletion uses the standard trash symbol:"
    echo "$delete_icon_hits" >&2
fi

# An SF Symbol from a release newer than the deployment target is not a build
# error and not a warning: `UIImage(systemName:)` returns nil and the button
# draws nothing. Xcode's own completion offers this year's symbols, so the only
# thing standing between a blank icon on iOS 15 and a release is this check.
# CoreGlyphs ships the availability table on every Mac; without it, skip — and
# skip on any other failure too (no python3, a CoreGlyphs layout that changes
# under a future macOS), which is what the `|| true` below is for. Under
# `set -e` this assignment would otherwise abort the whole release gate with a
# traceback instead of reporting the checks that did run.
symbol_hits="$(python3 - "$root" <<'PY'
import plistlib, re, subprocess, sys
root = sys.argv[1]
table = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
try:
    data = plistlib.load(open(table, "rb"))
except OSError:
    sys.exit(0)
minimum = re.search(r"IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+)", open(f"{root}/Configuration/Base.xcconfig").read())
floor = tuple(int(part) for part in minimum.group(1).split("."))
uses = re.compile(r'system(?:Name|Image|ImageName|SymbolName)\s*:\s*"([^"]+)"')
found = subprocess.run(
    ["grep", "-rn", "--include=*.swift", "-E", 'system(Name|Image|ImageName|SymbolName)', f"{root}/Fila", f"{root}/Packages/FilaKit/Sources/FilaTerminal"],
    capture_output=True, text=True).stdout
for line in found.splitlines():
    for name in uses.findall(line):
        release = data["year_to_release"].get(data["symbols"].get(name, ""), {}).get("iOS")
        if release and tuple(int(part) for part in release.split(".")) > floor:
            print(f"{line.split(':')[0]}:{line.split(':')[1]}: {name} needs iOS {release}")
PY
)" || true
if [[ -n "$symbol_hits" ]]; then
    error "these SF Symbols are newer than the deployment target and draw nothing on it:"
    echo "$symbol_hits" >&2
fi

# `XPC_TYPE_*`, `XPC_ARRAY_APPEND` and `XPC_ERROR_*` are Swift-overlay accessors
# exported by /usr/lib/swift/libswiftXPC.dylib, which iOS 15 does not have: one
# use makes dyld require the dylib and the app dies at launch. `FilaXPC` reads
# the same constants through C. See Packages/FilaKit/Sources/CFilaXPC.
#
# A warning rather than an error, and only below iOS 16: a project that has
# raised its floor above the overlay is entitled to use it, and this check has
# no business failing someone else's build for a choice that is theirs.
if (( minimum_ios_major < 16 )); then
    overlay_hits="$(search 'XPC_TYPE_[A-Z]|XPC_ARRAY_APPEND|XPC_ERROR_[A-Z]' \
        "$root/Fila" \
        "$root/Filad" \
        "$root/FilaArchive" \
        "$root/Packages/FilaKit/Sources")"
    if [[ -n "$overlay_hits" ]]; then
        echo "warning: XPC constants named in Swift link libswiftXPC.dylib, which iOS ${minimum_ios} does not have; use FilaXPC:" >&2
        echo "$overlay_hits" >&2
    fi
fi

daemon_hits="$(search 'import (SnapKit|Then|AlertController|SPIndicator)' \
    "$root/Filad" \
    "$root/FilaArchive" \
    "$root/Packages/FilaKit/Sources/FilaProtocol" \
    "$root/Packages/FilaKit/Sources/FilaFileOps" \
    "$root/Packages/FilaKit/Sources/FilaLog")"
if [[ -n "$daemon_hits" ]]; then
    error "SnapKit / Then / AlertController / SPIndicator must not link into the daemon or the file layer:"
    echo "$daemon_hits" >&2
fi

if [[ "$fail" -ne 0 ]]; then
    exit 65
fi
