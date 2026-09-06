#!/usr/bin/env python3
"""Resolve one entitlement template against the App Group baked into the app."""
import plistlib
import re
import sys
from pathlib import Path

if len(sys.argv) != 4:
    raise SystemExit("usage: resolve-app-group-entitlements.py <template> <app-info> <output>")
template, info, output = map(Path, sys.argv[1:])
with info.open("rb") as stream:
    group = plistlib.load(stream).get("FilaAppGroupIdentifier", "")
if not re.fullmatch(r"group\.[A-Za-z0-9.-]+", group):
    raise SystemExit("error: app has no resolved APP_GROUP_IDENTIFIER")
text = template.read_text().replace("$(APP_GROUP_IDENTIFIER)", group)
value = plistlib.loads(text.encode())
if value.get("com.apple.security.application-groups") != [group]:
    raise SystemExit("error: entitlement template does not name the app's group")
with output.open("wb") as stream:
    plistlib.dump(value, stream)
