#!/usr/bin/env python3
"""Delete every `extractionState: stale` key from the string catalogues.

A stale key is one Xcode extracted before and cannot find a call site for now:
either the string is dead, or its call site hides the literal from the
extractor (see Scripts/check-localization.sh rule 2). Either way it must not
sit in the catalogue — `check-localization.sh` fails on the marker, and this is
what fixes it.

The blocks are cut by line range rather than re-serialised, so the diff is
deletions only: a `json.dumps` round trip reorders keys and collapses Xcode's
empty `{\n\n    }` objects, which buries eighty real deletions under four
thousand lines of churn. The result is parsed back before it is written.

Usage: remove-stale-strings.py [--check] [root]
       --check reports and exits 1 instead of writing.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

MARKER = '"extractionState" : "stale"'


def prune(text: str) -> tuple[str, list[str]]:
    """Return the catalogue without its stale key blocks, and the keys cut."""
    lines = text.split("\n")
    kept: list[str] = []
    removed: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        # A key of the top-level `strings` object: four spaces, then `"key" : {`.
        if line.startswith('    "') and line.rstrip().endswith(" : {"):
            depth = 0
            end = i
            while end < len(lines):
                depth += lines[end].count("{") - lines[end].count("}")
                if depth == 0 and end > i:
                    break
                end += 1
            block = lines[i : end + 1]
            if MARKER in "\n".join(block):
                removed.append(line.strip()[1:-5])
            else:
                kept.extend(block)
            i = end + 1
        else:
            kept.append(line)
            i += 1
    # Cutting the last key of `strings` leaves the key before it with a comma
    # and nothing after it, which is not JSON.
    for index, line in enumerate(kept):
        if line == "  }," and index and kept[index - 1] == "    },":
            kept[index - 1] = "    }"
            break
    return "\n".join(kept), removed


def main() -> int:
    argv = sys.argv[1:]
    check_only = "--check" in argv
    argv = [a for a in argv if a != "--check"]
    root = Path(argv[0] if argv else Path(__file__).resolve().parent.parent)

    total = 0
    for catalogue in sorted(root.rglob("*.xcstrings")):
        if any(part in {".build", "Build", "DerivedData"} for part in catalogue.parts):
            continue
        text = catalogue.read_text(encoding="utf-8")
        if MARKER not in text:
            continue
        pruned, removed = prune(text)
        try:
            parsed = json.loads(pruned)
        except json.JSONDecodeError as error:
            print(f"error: {catalogue} would not parse after pruning: {error}", file=sys.stderr)
            return 70
        if any(v.get("extractionState") == "stale" for v in parsed.get("strings", {}).values()):
            print(f"error: {catalogue} still carries a stale key", file=sys.stderr)
            return 70
        total += len(removed)
        rel = catalogue.relative_to(root)
        print(f"{'stale in' if check_only else 'pruned'} {rel}: {len(removed)}")
        for key in removed:
            print(f"    {key}")
        if not check_only:
            catalogue.write_text(pruned, encoding="utf-8")

    if check_only and total:
        print(f"error: {total} stale keys; run `make remove-stale`", file=sys.stderr)
        return 1
    if total:
        print(f"strings: removed {total} stale keys")
    return 0


if __name__ == "__main__":
    sys.exit(main())
