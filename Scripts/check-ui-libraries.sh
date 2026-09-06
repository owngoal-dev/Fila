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

layout_hits="$(search 'NSLayoutConstraint|translatesAutoresizingMaskIntoConstraints|[A-Za-z]+Anchor\.constraint\(' "${ui_roots[@]}")"
if [[ -n "$layout_hits" ]]; then
    error "layout must use SnapKit; found NSLayoutConstraint / autoresizing-mask / anchor.constraint:"
    echo "$layout_hits" >&2
fi

alert_hits="$(search 'UIAlertController|UIAlertAction' "${ui_roots[@]}" \
    | grep -v 'Fila/Application/Diagnostics/IPAInstallProbe.swift' || true)"
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

# Escape dismissal is not a visible action; an empty action closure leaves
# touch-only users with no way to close the card.
empty_alert_hits="$(perl -0777 -ne '
    while (/allowSimpleDispose\(\)\s*\}/sg) {
        my $line = 1 + (substr($_, 0, $-[0]) =~ tr/\n//);
        print "$ARGV:$line: allowSimpleDispose needs a visible Close/OK action\n";
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
