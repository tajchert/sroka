#!/usr/bin/env bash
# Archive, preflight and upload the iOS app (Release-Prod) to App Store Connect / TestFlight.
#
#   scripts/release/ios.sh --check        # API key + app visibility only, no build
#   scripts/release/ios.sh                # archive -> preflight -> export .ipa -> preflight -> upload
#   scripts/release/ios.sh --skip-build   # upload build/export/Sroka.ipa as it is (still preflighted)
#
# The upload lands in TestFlight. Submitting for App Review stays a manual step in App Store Connect.
# Signing uses the Xcode account on this Mac (automatic signing, -allowProvisioningUpdates).
# Credentials: $CREDS_DIR/apple.env + $CREDS_DIR/AuthKey_<KEY_ID>.p8 (docs/releasing.md, "App Store").
set -euo pipefail
source "$(dirname "$0")/lib.sh"

CHECK=0 BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --skip-build) BUILD=0 ;;
    *) die "unknown option $1 (see header of $0)" ;;
  esac
  shift
done

require_cmd node
load_env apple.env
: "${ASC_KEY_ID:?apple.env needs ASC_KEY_ID}" "${ASC_ISSUER_ID:?apple.env needs ASC_ISSUER_ID}"
P8=$(creds_file "AuthKey_$ASC_KEY_ID.p8")

if [ "$CHECK" = 1 ]; then
  node "$REPO_ROOT/scripts/release/asc-check.mjs" "$P8" "$ASC_KEY_ID" "$ASC_ISSUER_ID" app.sroka
  exit
fi

IOS="$REPO_ROOT/apps/ios"
ARCHIVE="$IOS/build/Sroka.xcarchive"
EXPORT="$IOS/build/export"
IPA="$EXPORT/Sroka.ipa"

if [ "$BUILD" = 1 ]; then
  require_clean_tree
  require_cmd xcodebuild
  [ -f "$IOS/Config/GoogleService-Info.plist" ] || die "missing apps/ios/Config/GoogleService-Info.plist"
  TEAM=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]+).*/\1/p' "$IOS/Config/Local.xcconfig" 2>/dev/null | head -1)
  [ -n "$TEAM" ] || die "no DEVELOPMENT_TEAM in apps/ios/Config/Local.xcconfig"

  step "archive (Release-Prod)"
  rm -rf "$ARCHIVE" "$EXPORT"
  xcodebuild archive -quiet -project "$IOS/Sroka.xcodeproj" -scheme "Sroka Prod" -configuration Release-Prod \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates

  step "preflight archive"
  "$IOS/scripts/release-preflight.sh" "$ARCHIVE"

  step "export .ipa"
  mkdir -p "$IOS/build"
  cat >"$IOS/build/exportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -quiet -archivePath "$ARCHIVE" -exportOptionsPlist "$IOS/build/exportOptions.plist" \
    -exportPath "$EXPORT" -allowProvisioningUpdates
fi
[ -f "$IPA" ] || die "no .ipa at $IPA"

step "preflight .ipa"
"$IOS/scripts/release-preflight.sh" "$IPA"

step "upload to App Store Connect"
# altool finds AuthKey_<id>.p8 through API_PRIVATE_KEYS_DIR; the key path never appears in argv.
API_PRIVATE_KEYS_DIR=$CREDS_DIR xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format normal
echo "ok: uploaded; the build appears in TestFlight after processing (usually 5-30 min)"
echo "commit: $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
