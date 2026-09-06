#!/usr/bin/env python3
"""Check the signed device payload after extracting the finished archive."""
import plistlib
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT)


def setting(file, key):
    match = re.search(rf"^{key}\s*=\s*(\S+)", (ROOT / "Configuration" / file).read_text(), re.M)
    if not match:
        raise ValueError(f"missing {key} in {file}")
    return match[1]


def entitlements(template, group):
    return plistlib.loads((ROOT / "Packaging" / template).read_text().replace("$(APP_GROUP_IDENTIFIER)", group).encode())


def binary(path, expected, minimum):
    architectures = run("xcrun", "lipo", "-archs", str(path)).split()
    if b"arm64" not in architectures or set(architectures) - {b"arm64", b"arm64e"}:
        raise ValueError(f"not an arm64 device executable: {path}")
    build = run("xcrun", "vtool", "-show-build", str(path))
    platforms = re.findall(rb"^\s*platform\s+(\S+)", build, re.M)
    if platforms != [b"IOS"] * len(architectures):
        raise ValueError(f"not an iOS device binary: {path}")
    minimums = re.findall(rb"^\s*minos\s+(\S+)", build, re.M)
    limit = tuple(map(int, (minimum + ".0.0").split(".")[:3]))
    if len(minimums) != len(architectures) or any(tuple(map(int, (value.decode() + ".0.0").split(".")[:3])) > limit for value in minimums):
        raise ValueError(f"binary requires an OS newer than {minimum}: {path}")
    description = run("/usr/bin/codesign", "--display", "--verbose=2", str(path))
    if b"Signature=adhoc\n" not in description:
        raise ValueError(f"not ad-hoc signed: {path}")
    # ldid signs Mach-O code, not Apple's resource envelope or distribution
    # identity. Verify its code hashes without imposing either unrelated policy.
    run("/usr/bin/codesign", "--verify", "--all-architectures", "--ignore-resources", "-R=always", str(path))
    signed = run("ldid", "-e", str(path))
    actual = plistlib.loads(signed) if signed.strip() else {}
    if actual != expected:
        raise ValueError(f"unexpected or missing entitlements: {path}")


def main():
    if len(sys.argv) not in (4, 6):
        raise ValueError("usage: verify-payload.py <app> <deb|tipa|ipa> <version> [daemon helper]")
    app, kind, version = Path(sys.argv[1]).resolve(), sys.argv[2], sys.argv[3]
    if kind not in ("deb", "tipa", "ipa") or (len(sys.argv) == 6) != (kind == "deb"):
        raise ValueError("package kind does not match payload")
    for path in app.rglob("*"):
        if path.name == ".jbroot" or (path.is_symlink() and (not path.exists() or not path.resolve().is_relative_to(app))):
            raise ValueError(f"installed-device artifact or invalid bundle symlink: {path}")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    wanted = {
        "CFBundleIdentifier": "wiki.qaq.fila", "CFBundleExecutable": "Fila",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": setting("Version.xcconfig", "CURRENT_PROJECT_VERSION"),
        "MinimumOSVersion": setting("Base.xcconfig", "IPHONEOS_DEPLOYMENT_TARGET"),
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
    }
    for key, value in wanted.items():
        if info.get(key) != value:
            raise ValueError(f"app {key} is {info.get(key)!r}, expected {value!r}")
    group = info.get("FilaAppGroupIdentifier", "")
    if not re.fullmatch(r"group\.[A-Za-z0-9.-]+", group):
        raise ValueError("unresolved App Group identifier")
    template = "AppGroup.entitlements" if kind == "ipa" else "Fila.entitlements"
    minimum = wanted["MinimumOSVersion"]
    binary(app / "Fila", entitlements(template, group), minimum)
    provider = app / "PlugIns/FilaFileProvider.appex"
    template = "AppGroup.entitlements" if kind == "ipa" else "FilaFileProvider.entitlements"
    binary(provider / "FilaFileProvider", entitlements(template, group), "16.0")
    for folder, minimum in ((app / "Frameworks", minimum), (provider / "Frameworks", "16.0")):
        for library in folder.glob("*.dylib"):
            binary(library, {}, minimum)
        for framework in folder.glob("*.framework"):
            binary(framework / framework.stem, {}, minimum)
    for path in sys.argv[4:]:
        binary(Path(path), plistlib.loads((ROOT / "Packaging/Filad.entitlements").read_bytes()), wanted["MinimumOSVersion"])
    print("Verified device platform, build number, signatures and exact entitlements.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            print(error.output.decode(errors="replace"), file=sys.stderr)
        sys.exit(f"error: {error}")
