#!/bin/bash
# Downloads and copies pre-built xterm.js assets into WebResources/
# Run this script when updating xterm.js version.
# The output files are committed to the repository.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WEB_RESOURCES="$PROJECT_ROOT/Sources/Sessylph/Terminal/WebResources"
TMPDIR_NPM="$(mktemp -d)"

trap 'rm -rf "$TMPDIR_NPM"' EXIT

echo "Installing xterm.js packages..."
cd "$TMPDIR_NPM"
npm init -y --silent >/dev/null 2>&1
npm install --save \
  @xterm/xterm \
  @xterm/addon-canvas \
  @xterm/addon-fit \
  @xterm/addon-webgl \
  @xterm/addon-web-links \
  @xterm/addon-unicode11 \
  2>&1 | tail -1

echo "Copying files to $WEB_RESOURCES..."

# Core
cp node_modules/@xterm/xterm/lib/xterm.js "$WEB_RESOURCES/"
cp node_modules/@xterm/xterm/css/xterm.css "$WEB_RESOURCES/"

# Addons
cp node_modules/@xterm/addon-canvas/lib/addon-canvas.js "$WEB_RESOURCES/xterm-addon-canvas.js"
cp node_modules/@xterm/addon-fit/lib/addon-fit.js "$WEB_RESOURCES/xterm-addon-fit.js"
cp node_modules/@xterm/addon-webgl/lib/addon-webgl.js "$WEB_RESOURCES/xterm-addon-webgl.js"
cp node_modules/@xterm/addon-web-links/lib/addon-web-links.js "$WEB_RESOURCES/xterm-addon-web-links.js"
cp node_modules/@xterm/addon-unicode11/lib/addon-unicode11.js "$WEB_RESOURCES/xterm-addon-unicode11.js"

echo "Done. Files in $WEB_RESOURCES:"
ls -la "$WEB_RESOURCES/"*.js "$WEB_RESOURCES/"*.css 2>/dev/null || true
