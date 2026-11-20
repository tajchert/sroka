#!/usr/bin/env bash
# Renders the social preview card docs/brand/og.html to apps/web/public/og.png (1200×630) with headless Chrome.
# Output is committed; rerun only when the card changes. Needs network for the Outfit web font.
#   scripts/make-og.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
"$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1200,630 --virtual-time-budget=5000 \
  --screenshot="$root/apps/web/public/og.png" "file://$root/docs/brand/og.html" 2>/dev/null
echo "wrote apps/web/public/og.png"
