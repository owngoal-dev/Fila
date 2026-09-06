#!/usr/bin/env python3
"""Collect reviewed offline notices into Fila.app/Licenses.json.

The app's build phase runs after WebUI: repository LICENSE, vendored binary
notices, resolved Swift checkouts (including nested notices), then production
npm dependencies. Missing notices, changed text, and unreviewed binary upgrades
fail the build. See Licenses/README.md and Licenses/Compatibility.md.
"""

import argparse
import hashlib
import json
import os
import re
import sys

LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE)([-_.].*)?$", re.IGNORECASE)
SKIPPED_DIRECTORIES = {
    ".git", ".build", ".swiftpm", "Tests", "Test", "Example", "Examples",
    "docs", "Documentation", "node_modules", "Script", "Scripts", "Patches",
}
# Initial label suggestions only. The bundled labels come from review.json;
# keyword matches are never a compatibility decision.
LICENSE_KINDS = [

    ("Apache-2.0", re.compile(r"Apache License,?\s+Version 2\.0", re.IGNORECASE)),
    ("MPL-2.0", re.compile(r"Mozilla Public License,? (Version |v\.? ?)2\.0", re.IGNORECASE)),
    ("OFL-1.1", re.compile(r"SIL OPEN FONT LICENSE", re.IGNORECASE)),
    ("MIT", re.compile(r"MIT License|Permission is hereby granted, free of charge, to any person obtaining a copy\s+of this software", re.IGNORECASE)),
    ("BSD", re.compile(r"Redistribution and use in source and binary forms", re.IGNORECASE)),
    ("ISC", re.compile(r"ISC License|Permission to use, copy, modify, and/or distribute", re.IGNORECASE)),
    ("Unlicense", re.compile(r"This is free and unencumbered software", re.IGNORECASE)),
    ("Zlib", re.compile(r"This software is provided 'as-is', without any express or implied warranty", re.IGNORECASE)),
]


def fail(message):
    # Xcode reads "error:" lines into the issue navigator.
    print(f"error: collect-licenses: {message}", file=sys.stderr)
    sys.exit(1)


def read(path):
    with open(path, encoding="utf-8", errors="strict") as f:
        return f.read().strip("\n") + "\n"


def license_kind(text):
    kinds = [kind for kind, pattern in LICENSE_KINDS if pattern.search(text)]
    return " / ".join(kinds) or "Other"


def entry(name, version, url, text):
    kind = license_kind(text)
    item = {"name": name, "license": kind, "url": url, "text": text}
    if version:
        item["version"] = version
    return item


def xcconfig_setting(path, key):
    for line in read(path).splitlines():
        head, sep, value = line.partition("=")
        if sep and head.strip() == key:
            return value.split("//")[0].strip()
    fail(f"{key} is missing from {path}")


def app_entry(project):
    manifest = json.load(open(os.path.join(project, "manifest.json"), encoding="utf-8"))
    item = entry(
        "Fila",
        xcconfig_setting(os.path.join(project, "Configuration", "Version.xcconfig"), "MARKETING_VERSION"),
        manifest.get("homepage", ""),
        read(os.path.join(project, "LICENSE")),
    )
    item["id"] = "app/Fila"
    return item


def vendored_entries(project, checkouts):
    root = os.path.join(project, "Licenses")
    entries = []
    for folder in sorted(os.listdir(root)):
        directory = os.path.join(root, folder)
        if not os.path.isdir(directory):
            continue
        notice_path = os.path.join(directory, "notice.json")
        license_path = os.path.join(directory, "LICENSE")
        for required in (notice_path, license_path):
            if not os.path.isfile(required):
                fail(f"Licenses/{folder} lacks {os.path.basename(required)}")
        notice = json.load(open(notice_path, encoding="utf-8"))
        version = notice.get("version")
        version_file = notice.get("version_file")
        if version_file:
            path = os.path.join(checkouts, version_file)
            if not os.path.isfile(path):
                fail(f"Licenses/{folder}: version_file {version_file} is not in the package checkouts")
            version = read(path).strip()
        item = entry(notice["name"], version, notice.get("url", ""), read(license_path))
        item["id"] = "vendored/" + folder
        entries.append(item)
    return entries


def package_entries(project, checkouts):
    resolved_path = os.path.join(
        project, "Fila.xcodeproj", "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved"
    )
    resolved = json.load(open(resolved_path, encoding="utf-8"))
    entries = []
    for pin in sorted(resolved["pins"], key=lambda pin: pin["identity"]):
        location = pin["location"]
        url = location[:-4] if location.endswith(".git") else location
        package = url.rstrip("/").rsplit("/", 1)[-1]
        version = pin.get("state", {}).get("version") or pin.get("state", {}).get("revision")
        checkout = os.path.join(checkouts, package)
        if not os.path.isdir(checkout):
            fail(f"{package} is pinned in Package.resolved but has no checkout under {checkouts}")
        found = []
        for directory, subdirectories, files in os.walk(checkout):
            subdirectories[:] = sorted(d for d in subdirectories if d not in SKIPPED_DIRECTORIES)
            for filename in sorted(files):
                if LICENSE_FILE.match(filename) and not filename.endswith(".template"):
                    found.append(os.path.join(directory, filename))
        if not found:
            fail(f"{package} has no LICENSE, COPYING, or NOTICE file in its checkout")
        # The root license first, nested notices after it, so a package reads
        # as itself and then what it vendors.
        found.sort(key=lambda path: (os.path.dirname(path) != checkout, path))
        for path in found:
            relative_directory = os.path.relpath(os.path.dirname(path), checkout)
            stem = os.path.splitext(os.path.basename(path))[0]
            suffix = re.sub(r"^(LICEN[CS]E|COPYING|NOTICE)[-_.]?", "", stem, flags=re.IGNORECASE)
            if relative_directory == ".":
                name = package
            elif suffix:
                name = package + " / " + relative_directory + " / " + suffix
            else:
                name = package + " / " + relative_directory
            item = entry(name, version if relative_directory == "." else None, url, read(path))
            item["id"] = pin["identity"] + "/" + os.path.relpath(path, checkout)
            entries.append(item)
    return entries


def web_entries(project):
    """The shipped WebUI runtime dependencies, including transitive packages."""
    root = os.path.join(project, "WebUI")
    lock = json.load(open(os.path.join(root, "package-lock.json"), encoding="utf-8"))
    entries = []
    for relative, metadata in sorted(lock["packages"].items()):
        if not relative or metadata.get("dev"):
            continue
        directory = os.path.join(root, relative)
        if not os.path.isdir(directory):
            fail(f"{relative} is missing; build WebUI before collecting licenses")
        found = [name for name in sorted(os.listdir(directory)) if LICENSE_FILE.match(name)]
        if not found:
            fail(f"{relative} has no license notice")
        package = json.load(open(os.path.join(directory, "package.json"), encoding="utf-8"))
        for filename in found:
            item = entry(package["name"], metadata["version"], package.get("homepage", ""), read(os.path.join(directory, filename)))
            item["id"] = "web/" + relative + "/" + filename
            entries.append(item)
    return entries


def validate_review(project, entries):
    """Changed/new notices and binary upgrades require a fresh human review."""
    review = json.load(open(os.path.join(project, "Licenses", "review.json"), encoding="utf-8"))
    pins = json.load(open(os.path.join(project, "Fila.xcodeproj", "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved"), encoding="utf-8"))["pins"]
    revisions = {pin["identity"]: pin["state"]["revision"] for pin in pins}
    for package, revision in review["binaryRevisions"].items():
        if revisions.get(package) != revision:
            fail(f"{package} binary changed; review its bundled components and update Licenses/review.json")
    actual = {item["id"] for item in entries}
    expected = set(review["notices"])
    if len(actual) != len(entries) or actual != expected:
        fail(f"notice inventory changed; added={sorted(actual - expected)}, removed={sorted(expected - actual)}")
    for item in entries:
        reviewed = review["notices"][item["id"]]
        digest = hashlib.sha256(item["text"].encode("utf-8")).hexdigest()
        if reviewed["sha256"] != digest:
            fail(f"{item['id']} license text changed; review before updating its hash")
        item["license"] = reviewed["license"]


def find_source_packages(build_dir):
    """Xcode keeps SourcePackages beside Build/ in the derived data folder;
    BUILD_DIR is Build/Products for a build and a deeper archive path for an
    archive, so walk up until the sibling appears."""
    directory = os.path.abspath(build_dir)
    for _ in range(8):
        candidate = os.path.join(directory, "SourcePackages")
        if os.path.isdir(os.path.join(candidate, "checkouts")):
            return candidate
        parent = os.path.dirname(directory)
        if parent == directory:
            break
        directory = parent
    fail(f"no SourcePackages/checkouts above {build_dir}; resolve the packages first")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--project", required=True, help="the repository root (SRCROOT)")
    parser.add_argument("--build-dir", required=True, help="Xcode's BUILD_DIR, used to find SourcePackages")
    parser.add_argument("--output", required=True, help="where to write Licenses.json")
    arguments = parser.parse_args()

    checkouts = os.path.join(find_source_packages(arguments.build_dir), "checkouts")
    entries = [app_entry(arguments.project)]
    entries += vendored_entries(arguments.project, checkouts)
    entries += package_entries(arguments.project, checkouts)
    entries += web_entries(arguments.project)
    validate_review(arguments.project, entries)

    os.makedirs(os.path.dirname(arguments.output), exist_ok=True)
    with open(arguments.output, "w", encoding="utf-8") as f:
        json.dump(entries, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"collect-licenses: {len(entries)} licenses -> {arguments.output}")


if __name__ == "__main__":
    main()
