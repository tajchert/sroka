#!/usr/bin/env bash
# Build the Chrome Web Store zip and upload it with `wxt submit` (Chrome Web Store API v2, service account).
#
#   scripts/release/extension.sh --check     # authenticate only (wxt submit --dry-run), no build
#   scripts/release/extension.sh             # zip -> upload as a draft (nothing goes to review)
#   scripts/release/extension.sh --submit    # zip -> upload -> submit for review, STAGED: after approval you
#                                            #   press "Publish" in the dashboard
#   scripts/release/extension.sh --skip-build
#
# Credentials: $CREDS_DIR/chrome.env + $CREDS_DIR/chrome-service-account.json (docs/releasing.md, "Chrome Web Store").
set -euo pipefail
source "$(dirname "$0")/lib.sh"

CHECK=0 BUILD=1 SUBMIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --skip-build) BUILD=0 ;;
    --submit) SUBMIT=1 ;;
    *) die "unknown option $1 (see header of $0)" ;;
  esac
  shift
done

require_cmd jq
load_env chrome.env
: "${CHROME_EXTENSION_ID:?chrome.env needs CHROME_EXTENSION_ID}" "${CHROME_PUBLISHER_ID:?chrome.env needs CHROME_PUBLISHER_ID}"
SA=$(creds_file chrome-service-account.json)
# Passed as environment, never argv, so the key does not show up in `ps`.
CHROME_SERVICE_ACCOUNT_CLIENT_EMAIL=$(jq -r .client_email "$SA")
CHROME_SERVICE_ACCOUNT_PRIVATE_KEY=$(jq -r .private_key "$SA")
export CHROME_SERVICE_ACCOUNT_CLIENT_EMAIL CHROME_SERVICE_ACCOUNT_PRIVATE_KEY
export CHROME_API_VERSION=v2

EXT="$REPO_ROOT/apps/extension"
VERSION=$(jq -r .version "$EXT/package.json")
ZIP="$EXT/.output/srokaextension-$VERSION-chrome.zip"

submit() { (cd "$EXT" && npx wxt submit "$@"); }

if [ "$CHECK" = 1 ]; then
  [ -f "$ZIP" ] || ZIP=$(ls "$EXT"/.output/*-chrome.zip 2>/dev/null | head -1)
  [ -n "$ZIP" ] || die "--check needs any built zip in apps/extension/.output (npm run zip -w @sroka/extension)"
  submit --dry-run --chrome-zip "$ZIP"
  exit
fi

if [ "$BUILD" = 1 ]; then
  require_clean_tree
  [ -f "$EXT/analytics.config.json" ] || die "missing apps/extension/analytics.config.json (see apps/extension/CLAUDE.md)"
  step "zip (store build, no manifest key)"
  npm run --silent zip -w @sroka/extension >/dev/null
fi
[ -f "$ZIP" ] || die "no zip at $ZIP"
mkdir -p "$REPO_ROOT/store/upload"
cp "$ZIP" "$REPO_ROOT/store/upload/"

if [ "$SUBMIT" = 1 ]; then
  step "upload $VERSION and submit for review (staged publish)"
  submit --chrome-zip "$ZIP" --chrome-publish-type STAGED_PUBLISH
else
  step "upload $VERSION as a draft"
  submit --chrome-zip "$ZIP" --chrome-skip-submit-review
fi
echo "commit: $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
