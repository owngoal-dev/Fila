#!/usr/bin/env python3
"""Bind packaging to a successful build of the current source and exact outputs."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
INPUTS = ["Fila", "Frameworks", "Filad", "FilaArchive", "FilaFileProvider", "FilaSaveAction", "Fila.xcodeproj", "Configuration", "Packaging", "Licenses", "Scripts", "WebUI", "Packages/FilaKit", "Makefile"]
PRODUCTS = ["Fila.app", "filad", "fila-archive"]


def digest(paths, base):
    result = hashlib.sha256()
    for path in sorted(paths):
        result.update(os.fsencode(str(path.relative_to(base))) + b"\0")
        if path.is_symlink():
            result.update(b"link\0" + os.fsencode(os.readlink(path)))
        elif path.is_file():
            result.update(f"{path.stat().st_mode & 0o777:o}\0".encode())
            with path.open("rb") as stream:
                while block := stream.read(1024 * 1024):
                    result.update(block)
        else:
            raise ValueError(f"missing build input: {path}")
        result.update(b"\0")
    return result.hexdigest()


def source_digest():
    names = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *INPUTS], cwd=ROOT).split(b"\0")
    paths = {ROOT / os.fsdecode(name) for name in names if name}
    # Submodule contents are build inputs too, including local edits.
    expanded = set()
    for path in paths:
        if path.is_dir() and not path.is_symlink():
            expanded.update(p for p in path.rglob("*") if p.is_file() or p.is_symlink())
        elif path.exists() or path.is_symlink():
            expanded.add(path)
    expanded.update((ROOT / "Configuration").glob("*.xcconfig"))
    return digest(expanded, ROOT)


def product_digest(directory):
    paths = []
    for name in PRODUCTS:
        path = directory / name
        if not path.exists():
            raise ValueError(f"missing build product: {path}")
        if path.is_dir():
            paths.extend(p for p in path.rglob("*") if p.is_file() or p.is_symlink())
        else:
            paths.append(path)
    return digest(paths, directory)


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("build", "verify"):
        raise ValueError("usage: build-package-inputs.py build <products> <build command...> | verify <products>")
    mode, directory = sys.argv[1], Path(sys.argv[2]).resolve()
    receipt = directory / "FilaBuild.json"
    if mode == "build":
        if len(sys.argv) < 4:
            raise ValueError("missing build command")
        receipt.unlink(missing_ok=True)
        source = source_digest()
        subprocess.run(sys.argv[3:], check=True, cwd=ROOT)
        if source_digest() != source:
            raise ValueError("build inputs changed during compilation; rebuild before packaging")
        value = {"source": source, "products": product_digest(directory)}
        temporary = receipt.with_suffix(f".tmp.{os.getpid()}")
        try:
            temporary.write_text(json.dumps(value, indent=2) + "\n")
            temporary.replace(receipt)
        finally:
            temporary.unlink(missing_ok=True)
        print("Recorded verified build inputs and product hashes.")
    else:
        if len(sys.argv) != 3:
            raise ValueError("unexpected verification arguments")
        if not receipt.is_file():
            raise ValueError("no successful build receipt; run make build before packaging")
        receipt_bytes = receipt.read_bytes()
        value = json.loads(receipt_bytes)
        if value.get("source") != source_digest():
            raise ValueError("source differs from the last successful build; rebuild before packaging")
        if value.get("products") != product_digest(directory):
            raise ValueError("build products changed after compilation; rebuild before packaging")
        print(hashlib.sha256(receipt_bytes).hexdigest())


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: {error}")
