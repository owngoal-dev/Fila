#!/usr/bin/env python3
"""Check IconServices access in entitlements read back from a deb/tipa app."""

import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    entitlements = plistlib.load(source)

services = entitlements.get("com.apple.security.exception.mach-lookup.global-name", [])
for service in ("com.apple.iconservices", "com.apple.iconservices.store"):
    if not isinstance(services, list) or service not in services:
        raise SystemExit(f"error: signed app is missing IconServices mach lookup: {service}")
