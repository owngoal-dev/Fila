#!/usr/bin/env python3
"""Diff each string catalogue against the keys Xcode's extractor actually found.

A key missing from a catalogue is not a build failure and never warns: the
runtime renders the English key itself on a Chinese device, silently. So it has
to be checked, and checked against the compiler rather than a grep — a grep
cannot see SwiftUI's bare `Text("Grid")` and cannot see an interpolated key,
which is looked up as `%lld selected` rather than as anything you typed.

A release build emits one `.stringsdata` per source file, whose
`tables.Localizable` is the exact set of keys the runtime will look up.

Two traps this script exists to avoid:

*   `GeneratedStringSymbols_Localizable.stringsdata` is generated *from the
    catalogue*, not from source. Counting it makes the comparison circular and
    reports a perfect match no matter how many keys are unextractable. It is
    excluded here, deliberately.
*   Xcode's extractor only walks one target. A `String(localized:)` in a
    package target never reaches the app's `.stringsdata`, so each target that
    shows the user a sentence owns its own catalogue and is diffed separately.

Usage: check-extracted-strings.py [--composition full|sandboxed] <derived-data-path> [configuration-platform]

The sandboxed composition never compiles the applications and music
modules, so their catalogues are not looked for in its DerivedData; the
full build is where those two are checked.
"""

import json
import pathlib
import plistlib
import sys

# Each target that ships user-facing strings, and where its two halves live.
TARGETS = [
    ("Fila", "Fila.build", "Fila/Resources/Localizable.xcstrings"),
    ("FilaSaveAction", "Fila.build", "FilaSaveAction/Localizable.xcstrings"),
    # Module frameworks compile their package sources themselves, so their
    # strings land in the framework's own .stringsdata, not FilaKit's.
    ("FilaApplications", "Fila.build", "Frameworks/FilaApplications/Resources/Localizable.xcstrings"),
    ("FilaMusicLibrary", "Fila.build", "Frameworks/FilaMusicLibrary/Resources/Localizable.xcstrings"),
    (
        "FilaFormats",
        "FilaKit.build",
        "Packages/FilaKit/Sources/FilaFormats/Resources/Localizable.xcstrings",
    ),
    (
        "FilaMedia",
        "FilaKit.build",
        "Packages/FilaKit/Sources/FilaMedia/Resources/Localizable.xcstrings",
    ),
    (
        "FilaTerminal",
        "FilaKit.build",
        "Packages/FilaKit/Sources/FilaTerminal/Resources/Localizable.xcstrings",
    ),
]

# What each composition compiles: catalogue owner → the Xcode target whose
# intermediates hold its .stringsdata. The sandboxed app is a second target
# over the same sources and catalogue, so its keys land under its own name.
# See verify-composition.sh for the same split read back out of the product.
COMPOSITIONS = {
    "full": {name: name for name, _, _ in TARGETS},
    "sandboxed": {
        name: ("FilaSandboxed" if name == "Fila" else name)
        for name, _, _ in TARGETS
        if name not in ("FilaApplications", "FilaMusicLibrary")
    },
}


def target_build_dirs(intermediates: pathlib.Path, project: str, configuration: str, name: str) -> list[pathlib.Path]:
    # Xcode 26 uses Target.build; Xcode 27 adds -t for package code targets.
    # Match exact names so resource bundle and similarly named targets stay out.
    parent = intermediates / project / configuration
    return [path for suffix in (".build", "-t.build") if (path := parent / f"{name}{suffix}").is_dir()]


def extracted_keys(build_dir: pathlib.Path) -> set[str]:
    """Every key the compiler recorded for this target, from source alone."""
    keys: set[str] = set()
    for path in build_dir.rglob("*.stringsdata"):
        # Generated back out of the catalogue: counting it compares the
        # catalogue with itself.
        if path.name.startswith("GeneratedStringSymbols"):
            continue
        raw = path.read_bytes()
        try:
            table = json.loads(raw)
        except ValueError:
            try:
                table = plistlib.loads(raw)
            except Exception:
                continue
        for entry in table.get("tables", {}).get("Localizable", []):
            key = entry.get("key")
            if key:
                keys.add(key)
    return keys


def main() -> int:
    arguments = sys.argv[1:]
    composition = "full"
    if arguments[:1] == ["--composition"]:
        composition = arguments[1] if len(arguments) > 1 else ""
        arguments = arguments[2:]
    if composition not in COMPOSITIONS or len(arguments) not in (1, 2):
        print(
            "usage: check-extracted-strings.py [--composition full|sandboxed] <derived-data-path> [configuration-platform]",
            file=sys.stderr,
        )
        return 64
    root = pathlib.Path(__file__).resolve().parent.parent
    intermediates = pathlib.Path(arguments[0]) / "Build/Intermediates.noindex"
    if not intermediates.is_dir():
        print(f"error: no build products under {intermediates}", file=sys.stderr)
        return 66

    configuration = arguments[1] if len(arguments) == 2 else "Release-iphoneos"
    failed = False
    for name, project, catalogue_path in TARGETS:
        build_name = COMPOSITIONS[composition].get(name)
        if build_name is None:
            continue
        catalogue = root / catalogue_path
        if not catalogue.is_file():
            print(f"error: {catalogue_path} is missing", file=sys.stderr)
            failed = True
            continue
        build_dirs = target_build_dirs(intermediates, project, configuration, build_name)
        if not build_dirs:
            print(
                f"error: no build directory for {name} in {project}/{configuration}; "
                f"the catalogue cannot be checked",
                file=sys.stderr,
            )
            failed = True
            continue

        found: set[str] = set()
        for build_dir in build_dirs:
            found |= extracted_keys(build_dir)
        listed = set(json.loads(catalogue.read_text())["strings"])

        missing = sorted(found - listed)
        orphaned = sorted(listed - found)
        if missing:
            print(
                f"error: {catalogue_path} is missing {len(missing)} key(s) the "
                f"{name} sources look up. They render as English on every "
                f"translated device:",
                file=sys.stderr,
            )
            for key in missing[:20]:
                print(f"    + {key!r}", file=sys.stderr)
            failed = True
        if orphaned:
            print(
                f"error: {catalogue_path} carries {len(orphaned)} key(s) no "
                f"{name} source extracts. Either the string is dead and the "
                f"entry should go, or its call site hides the literal from the "
                f"extractor — wrap it in String.LocalizationValue(...):",
                file=sys.stderr,
            )
            for key in orphaned[:20]:
                print(f"    - {key!r}", file=sys.stderr)
            failed = True
        if not missing and not orphaned:
            print(f"{name}: {len(listed)} keys, all extracted from source")

    return 65 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
