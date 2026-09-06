#!/usr/bin/env python3
"""Integration regressions against freshly built products; writes only in tmp."""
import hashlib
import json
import plistlib
import zipfile
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "Scripts"
products = Path(sys.argv[1]).resolve()
version = subprocess.check_output(["make", "--no-print-directory", "print-version"], cwd=ROOT, text=True).strip()


def run(args, *, success=True, env=None):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if (result.returncode == 0) != success:
        raise AssertionError(result.stdout)
    return result.stdout


with tempfile.TemporaryDirectory(prefix="fila-package-test-") as workspace:
    work = Path(workspace)
    run(["python3", SCRIPTS / "build-package-inputs.py", "verify", products])
    # A failed build must invalidate its previous receipt, even if products remain.
    failed = work / "failed"
    failed.mkdir()
    (failed / "FilaBuild.json").write_text('{}')
    run(["python3", SCRIPTS / "build-package-inputs.py", "build", failed, "/usr/bin/false"], success=False)
    assert not (failed / "FilaBuild.json").exists()
    print("PASS failed build invalidates receipt")

    copied = work / "products"
    run(["/usr/bin/ditto", products, copied])
    run(["python3", SCRIPTS / "build-package-inputs.py", "verify", copied])
    with (copied / "Fila.app/WebUI/app.js").open("ab") as stream:
        stream.write(b"\n/* test changed product */\n")
    output = run(["python3", SCRIPTS / "build-package-inputs.py", "verify", copied], success=False)
    assert "build products changed" in output
    print("PASS changed build product rejected")
    receipt = copied / "FilaBuild.json"
    value = json.loads(receipt.read_text())
    value["source"] = "different source"
    receipt.write_text(json.dumps(value))
    output = run(["python3", SCRIPTS / "build-package-inputs.py", "verify", copied], success=False)
    assert "source differs" in output
    print("PASS stale source receipt rejected")

    good = work / "good.ipa"
    run(["bash", SCRIPTS / "package-ipa.sh", products / "Fila.app", "ipa", good, version])
    payload = work / "payload"
    with zipfile.ZipFile(good) as archive:
        archive.extractall(payload)
    app = payload / "Payload/Fila.app"
    # zipfile does not restore Unix executable modes; verification below is
    # concerned with the signed bytes and metadata of this known-good archive.
    verifier = ["python3", SCRIPTS / "verify-payload.py", app, "ipa", version]
    run(verifier)
    executable = app / "Fila"
    original = executable.read_bytes()
    changed = bytearray(original)
    changed[32768] ^= 1
    executable.write_bytes(changed)
    result = run(verifier, success=False)
    assert "invalid signature" in result or "modified" in result, result
    executable.write_bytes(original)
    print("PASS altered signed code rejected")
    info_path = app / "Info.plist"
    original_info = info_path.read_bytes()
    info = plistlib.loads(original_info)
    info["CFBundleVersion"] = "999999"
    info_path.write_bytes(plistlib.dumps(info))
    result = run(verifier, success=False)
    assert "CFBundleVersion" in result
    info_path.write_bytes(original_info)
    print("PASS mismatched build number rejected")
    (app / ".jbroot").symlink_to("/nonexistent-fila-test-target")
    result = run(verifier, success=False)
    assert "invalid bundle symlink" in result
    (app / ".jbroot").unlink()
    print("PASS installed-device symlink rejected")

    # Corrupt the packager's output after compression. Both packagers must
    # reject it before replacing an already published artifact.
    wrappers = work / "bin"
    wrappers.mkdir()
    for tool in ("zip", "dpkg-deb"):
        real = shutil.which(tool)
        wrapper = wrappers / tool
        if tool == "zip":
            body = 'if [[ "$1" == -qry ]]; then printf broken > "$2"; exit 0; fi'
        else:
            body = 'if [[ " $* " == *" -b "* ]]; then printf broken > "${@: -1}"; exit 0; fi'
        wrapper.write_text(f'#!/bin/bash\n{body}\nexec "{real}" "$@"\n')
        wrapper.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = str(wrappers) + os.pathsep + environment["PATH"]
    for kind in ("ipa", "deb"):
        output = work / f"published.{kind}"
        output.write_bytes(b"previous verified artifact")
        previous = hashlib.sha256(output.read_bytes()).digest()
        if kind == "ipa":
            command = ["bash", SCRIPTS / "package-ipa.sh", products / "Fila.app", kind, output, version]
        else:
            command = ["bash", SCRIPTS / "package-deb.sh", products / "Fila.app", products / "filad", products / "fila-archive",
                       ROOT / "Packaging/DEBIAN/control", ROOT / "Packaging/Fila.entitlements", ROOT / "Packaging/Filad.entitlements",
                       ROOT / "Packaging/wiki.qaq.filad.plist", output, "wiki.qaq.fila", version, "iphoneos-arm64", "rootless", "/var/jb"]
        result = run(command, success=False, env=environment)
        assert "Signed" in result, result  # reached compression, not a stale-input rejection
        assert hashlib.sha256(output.read_bytes()).digest() == previous
        assert not list(work.glob(".fila-package.*"))
        print(f"PASS corrupted {kind} rejected; published artifact preserved; staging cleaned")
print("Packaging regression tests passed.")
