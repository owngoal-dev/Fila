#!/bin/bash
# Builds the browser frontend in WebUI/ with webpack and, when run as an Xcode
# build phase, copies dist/ into the app bundle as Fila.app/WebUI. The server
# reads index.html, app.js and app.css from there at runtime.
#
# Standalone: `make webui` or `Scripts/build-webui.sh` just refreshes WebUI/dist.
set -euo pipefail

root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
command -v npm >/dev/null || { echo "error: npm is required to build the web UI (brew install node)" >&2; exit 69; }

cd "$root/WebUI"
if [[ ! -d node_modules || package-lock.json -nt node_modules/.package-lock.json ]]; then
    npm ci --no-fund --no-audit
fi
npm run build
for file in index.html app.js app.css; do
    [[ -f "dist/$file" ]] || { echo "error: WebUI build did not produce dist/$file" >&2; exit 65; }
done

if [[ -n "${BUILT_PRODUCTS_DIR:-}" && -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
    target="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/WebUI"
    rm -rf "$target"
    mkdir -p "$target"
    cp -R dist/. "$target/"
fi
