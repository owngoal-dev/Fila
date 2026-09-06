#!/bin/bash
# Fast UI iteration on the VM. Release validation remains `make deb`.
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "usage: $0 (install and check features in vphone)" >&2
    exit 64
fi

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
package="${DEB_OUTPUT:-$root/build/Packages/Fila-vphone.deb}"
build_arguments=(
    --no-print-directory
    CONFIGURATION=Debug
    "FLAVOR=${FLAVOR:-rootless}"
    "DERIVED_DATA=${DERIVED_DATA:-/private/tmp/fila-vphone-deriveddata}"
    "DEB_OUTPUT=$package"
)

echo "==> vphone: incremental Debug build (release checks skipped)"
started=$SECONDS
make "${build_arguments[@]}" _build-ios
echo "==> build: $((SECONDS - started))s"

phase=$SECONDS
make "${build_arguments[@]}" _package-deb
echo "==> sign/package: $((SECONDS - phase))s"

echo "==> package ready: $package; total: $((SECONDS - started))s"

python3 - "$package" "$root/Scripts/vphone-ui.py" <<'PY'
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from ipaddress import IPv4Address
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory

try:
    host = IPv4Address(os.environ.get("VPHONE_HTTP_HOST", "192.168.64.1"))
    port = int(os.environ.get("VPHONE_HTTP_PORT", "8765"))
    if host.is_unspecified or not 1 <= port <= 65535:
        raise ValueError("use a specific host IPv4 address and a port from 1 to 65535")
except ValueError as error:
    raise SystemExit(f"Invalid VPHONE_HTTP_HOST / VPHONE_HTTP_PORT: {error}")

try:
    # Serve one package from a disposable directory, never the repository.
    with TemporaryDirectory(prefix="fila-vphone-") as directory:
        checksum = hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()
        filename = f"Fila-{checksum[:12]}.deb"
        shutil.copyfile(sys.argv[1], Path(directory) / filename)
        handler = partial(SimpleHTTPRequestHandler, directory=directory)
        with ThreadingHTTPServer((str(host), port), handler) as server:
            url = f"http://{host}:{port}/{filename}"
            print(f"\nDownload: {url}", flush=True)
            command = json.dumps({"t": "type", "text": url, "screen": False})
            try:
                subprocess.run([sys.executable, sys.argv[2], command], check=True)
                print("Download URL placed in the guest clipboard.")
            except (OSError, subprocess.CalledProcessError) as error:
                print(f"Clipboard unavailable; enter the URL manually: {error}", file=sys.stderr)
            print(f"Package SHA-256: {checksum}")
            print(f"1. In vphone Safari, paste the URL and download {filename}.")
            print(f"2. Open Files > Recents, tap {filename}, then install it in Sileo.")
            print("3. After installation, close the old Fila in the App Switcher and reopen Fila.")
            print("Same-version rebuilds: remove only Fila's old .deb from Sileo's APT cache in Fila before installing.")
            print("Installation and runtime checks have not run yet.")
            print("Keep this server running until the download finishes. Ctrl-C stops it.", flush=True)
            server.serve_forever()
except KeyboardInterrupt:
    print("\nDownload server stopped.")
PY
