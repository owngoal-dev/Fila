#!/usr/bin/env python3
"""Send one UI command to the running vphone's native socket. No SSH.

Example: vphone-ui.py '{"t":"screenshot","path":"/tmp/fila.png"}'
Commands: screenshot, tap, swipe, key, type (sets the guest clipboard).
VPHONE_SOCKET overrides the current VM's socket path.
"""
import json
import os
from pathlib import Path
import socket
import sys


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    command = json.loads(sys.argv[1])
    if command.get("t") not in {"screenshot", "tap", "swipe", "key", "type"}:
        raise SystemExit("Unsupported UI command")
    endpoint = os.environ.get("VPHONE_SOCKET", str(Path.home() / ".vphone/VMs/vphone/vphone.sock"))
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(20)
        connection.connect(endpoint)
        connection.sendall((json.dumps(command) + "\n").encode())
        with connection.makefile("rb") as stream:
            response = stream.readline(2 * 1024 * 1024)
    if not response.endswith(b"\n"):
        raise SystemExit("Incomplete vphone response")
    result = json.loads(response)
    result.pop("image", None)
    print(json.dumps(result, ensure_ascii=False))
    if not result.get("ok"):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
