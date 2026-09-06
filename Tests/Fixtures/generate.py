#!/usr/bin/env python3
"""Create isolated, reproducible file-operation inputs using only the stdlib."""

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile


def archive(path):
    entries = [
        ("./", None),
        ("./control", b"Package: wiki.qaq.fila.fixture-files\nVersion: 1.0\nArchitecture: all\nDescription: Fila archive preview fixture only\n"),
        ("./note.txt", "Fila archive fixture. 文件图标和解压名称测试。\n".encode("utf-8")),
        ("./images/", None),
    ]
    with path.open("xb") as output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as tar:
                for name, content in entries:
                    entry = tarfile.TarInfo(name)
                    entry.mtime = 0
                    entry.uid = entry.gid = 0
                    entry.uname = entry.gname = ""
                    entry.mode = 0o755 if content is None else 0o644
                    if content is None:
                        entry.type = tarfile.DIRTYPE
                        tar.addfile(entry)
                    else:
                        entry.size = len(content)
                        tar.addfile(entry, io.BytesIO(content))


def progress(path, seed, size_mib):
    # Each MiB is an independent SHAKE-256 stream. The decimal seed and block
    # number fully define the bytes, independent of Python's random module.
    with path.open("xb") as output:
        for block in range(size_mib):
            key = f"Fila ProgressFixture v1:{seed}:{block}".encode("ascii")
            output.write(hashlib.shake_256(key).digest(1024 * 1024))


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new directory; its parent must already exist")
    parser.add_argument("--seed", type=int, default=20260906, help="deterministic progress-data seed (default: 20260906)")
    parser.add_argument("--progress-mib", type=int, default=64, help="progress file size, 0 to omit, maximum 1024 (default: 64)")
    args = parser.parse_args()
    if not 0 <= args.progress_mib <= 1024:
        parser.error("--progress-mib must be between 0 and 1024")
    if not 0 <= args.seed <= 2**64 - 1:
        parser.error("--seed must fit an unsigned 64-bit integer")

    destination = args.output.expanduser()
    try:
        # Exclusive creation refuses existing files, directories and symlinks.
        destination.mkdir(mode=0o700)
    except OSError as error:
        parser.error(f"cannot create a new output directory: {error}")

    try:
        archive(destination / "control.tar.gz")
        text_files = {
            "TrashFixture.txt": "Fila trash fixture. Verify trash, Put Back and unchanged bytes.\n",
            "CrossVolumeFixture.txt": "Fila cross-volume fixture. Verify the result and preserve this source on failure.\n",
        }
        for name, content in text_files.items():
            with (destination / name).open("x", encoding="utf-8", newline="\n") as output:
                output.write(content)
        if args.progress_mib:
            progress(destination / "ProgressFixture.bin", args.seed, args.progress_mib)

        files = {
            item.name: {"bytes": item.stat().st_size, "sha256": digest(item)}
            for item in sorted(destination.iterdir())
        }
        manifest = {"format": 1, "seed": args.seed, "progress_mib": args.progress_mib, "files": files}
        with (destination / "Manifest.json").open("x", encoding="utf-8") as output:
            json.dump(manifest, output, ensure_ascii=False, indent=2)
            output.write("\n")
        with (destination / "SHA256SUMS.txt").open("x", encoding="utf-8") as output:
            for name, record in files.items():
                output.write(f"{record['sha256']}  {name}\n")
    except Exception as error:
        print(f"Generation failed; partial files remain only in {destination}: {error}", file=sys.stderr)
        return 1

    print(f"Created and hashed {len(files)} fixtures in {destination.resolve()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
