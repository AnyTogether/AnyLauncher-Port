#!/bin/sh
# Copies the browser pad page from the macOS launcher, where it is written, into this launcher's
# assets: both serve the same file. Usage: tool/sync_browser_pad.sh [path to AnyPS5-ARM checkout]
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
arm="${1:-$here/../anyps5/AnyPS5}"
cp "$arm/tools/macos/launcher/BrowserPad/index.html" "$here/assets/browser_pad/index.html"
echo "copied $(wc -c < "$here/assets/browser_pad/index.html") bytes from $arm"
