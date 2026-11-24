#!/usr/bin/env bash
# Release preflight for an iOS artifact. Modelled on the repo-root scripts/release-preflight.sh (Android).
#
#   scripts/release-preflight.sh <path to .xcarchive | .ipa | .app>
#   scripts/release-preflight.sh --self-test [path to a built Sroka.app]
#
# Fails (non-zero) if the artifact:
#   - has no GoogleService-Info.plist, or one that is the placeholder (project id / any value containing
#     "sroka-example"), or whose PROJECT_ID / BUNDLE_ID is not the expected one;
#   - contains "sroka-example" anywhere in the bundle;
#   - is not distribution-signed (an .ipa must be signed "Apple Distribution", get-task-allow false, a profile without a
#     device list; an .xcarchive must be a device build signed by a real team certificate with get-task-allow false;
#     a bare .app must pass the .ipa rules);
#   - has an unexpected bundle id, version, API base URL or share-extension id/version.
# Overrides: EXPECTED_BUNDLE_ID (app.sroka), EXPECTED_FIREBASE_PROJECT (sroka-95489), EXPECTED_API_BASE_URL
# (https://api.sroka.app), EXPECTED_VERSION (any x.y or x.y.z when unset).
# Needs only macOS tools: unzip, plutil, PlistBuddy, codesign, security, grep.
set -euo pipefail

EXPECTED_BUNDLE_ID=${EXPECTED_BUNDLE_ID:-app.sroka}
EXPECTED_FIREBASE_PROJECT=${EXPECTED_FIREBASE_PROJECT:-sroka-95489}
EXPECTED_API_BASE_URL=${EXPECTED_API_BASE_URL:-https://api.sroka.app}
EXPECTED_VERSION=${EXPECTED_VERSION:-}
PLISTBUDDY=/usr/libexec/PlistBuddy
PLACEHOLDER=sroka-example

FAILED=0
bad() { echo "preflight FAIL: $*" >&2; FAILED=1; }
usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# plist_get <file> <key> -> value on stdout, empty when missing.
plist_get() { "$PLISTBUDDY" -c "Print :$2" "$1" 2>/dev/null || true; }

# Entitlements of a signed bundle as XML on stdout (empty when unsigned).
entitlements_of() { codesign -d --entitlements - --xml "$1" 2>/dev/null || true; }

# check_bundle_id_and_version <app-or-appex> <expected id> <label>; sets VERSION_SEEN.
check_identity() {
  local bundle=$1 want_id=$2 label=$3 plist id short build
  plist="$bundle/Info.plist"
  [ -f "$plist" ] || { bad "$label: no Info.plist in $bundle"; return; }
  id=$(plist_get "$plist" CFBundleIdentifier)
  short=$(plist_get "$plist" CFBundleShortVersionString)
  build=$(plist_get "$plist" CFBundleVersion)
  [ "$id" = "$want_id" ] || bad "$label: bundle id is '$id', expected '$want_id'"
  if [ -n "$EXPECTED_VERSION" ]; then
    [ "$short" = "$EXPECTED_VERSION" ] || bad "$label: version is '$short', expected '$EXPECTED_VERSION'"
  else
    grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' <<<"$short" || bad "$label: version '$short' is not x.y or x.y.z"
  fi
  grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' <<<"$build" || bad "$label: build number '$build' is not numeric"
  VERSION_SEEN="$short ($build)"
}

# check_firebase <app>: the bundled GoogleService-Info.plist.
check_firebase() {
  local app=$1 gs="$1/GoogleService-Info.plist" project bundle
  if [ ! -f "$gs" ]; then
    bad "no GoogleService-Info.plist in the app bundle (copy the real one to Config/GoogleService-Info.plist and rebuild)"
    return
  fi
  plutil -lint "$gs" >/dev/null 2>&1 || { bad "GoogleService-Info.plist is not a valid plist"; return; }
  project=$(plist_get "$gs" PROJECT_ID)
  bundle=$(plist_get "$gs" BUNDLE_ID)
  [ -n "$(plist_get "$gs" API_KEY)" ] && [ -n "$(plist_get "$gs" GOOGLE_APP_ID)" ] \
    || bad "GoogleService-Info.plist lacks API_KEY or GOOGLE_APP_ID"
  if grep -qiF "$PLACEHOLDER" "$gs" || [[ "$project" == *"$PLACEHOLDER"* ]]; then
    bad "GoogleService-Info.plist is the placeholder ('$PLACEHOLDER')"
  fi
  [ "$project" = "$EXPECTED_FIREBASE_PROJECT" ] || bad "Firebase PROJECT_ID is '$project', expected '$EXPECTED_FIREBASE_PROJECT'"
  [ "$bundle" = "$EXPECTED_BUNDLE_ID" ] || bad "Firebase BUNDLE_ID is '$bundle', expected '$EXPECTED_BUNDLE_ID'"
}

# check_signing <app> <ipa|archive>
check_signing() {
  local app=$1 kind=$2 info ents gta auth profile decoded team platform
  info=$(codesign -dvv "$app" 2>&1) || { bad "app is ad-hoc signed or unsigned (not a distribution build)"; return; }
  if grep -q 'Signature=adhoc' <<<"$info" || ! grep -q '^Authority=' <<<"$info"; then
    bad "app is ad-hoc signed or unsigned (simulator / unsigned build)"
    return
  fi
  platform=$(plist_get "$app/Info.plist" CFBundleSupportedPlatforms:0)
  [ "$platform" = "iPhoneOS" ] || bad "not a device build (CFBundleSupportedPlatforms is '$platform')"
  auth=$(grep '^Authority=' <<<"$info" | head -1 | sed 's/^Authority=//')
  team=$(grep '^TeamIdentifier=' <<<"$info" | head -1 | sed 's/^TeamIdentifier=//')
  ents=$(entitlements_of "$app")
  gta=$(printf '%s' "$ents" | plutil -extract get-task-allow raw -o - - 2>/dev/null || true)
  # A development-signed archive is normal with automatic signing: the export re-signs it for distribution, and the
  # exported .ipa gets the strict checks. So get-task-allow and the profile's device list only count elsewhere.
  local dev_archive=0
  case "$kind:$auth" in archive:"Apple Development"*|archive:"iPhone Developer"*) dev_archive=1 ;; esac
  [ -z "$ents" ] || [ "$gta" != "true" ] || [ "$dev_archive" = 1 ] ||
    bad "get-task-allow is true (development-signed, not for distribution)"
  case "$kind" in
    ipa)
      case "$auth" in
        "Apple Distribution"*|"iPhone Distribution"*) ;;
        *) bad "signing identity is '$auth', expected an Apple Distribution certificate" ;;
      esac
      ;;
    archive)
      case "$auth" in
        "Apple Distribution"*|"iPhone Distribution"*|"Apple Development"*|"iPhone Developer"*) ;;
        *) bad "signing identity is '$auth', expected a team certificate" ;;
      esac
      case "$auth" in
        "Apple Development"*|"iPhone Developer"*)
          echo "preflight note: archive is signed '$auth'; export re-signs it, so run the preflight on the exported .ipa too" >&2 ;;
      esac
      ;;
  esac
  [ -n "$team" ] && [ "$team" != "not set" ] || bad "no TeamIdentifier"
  # The embedded profile: a distribution profile has no device list (ad hoc / development do).
  profile="$app/embedded.mobileprovision"
  if [ -f "$profile" ]; then
    decoded=$(security cms -D -i "$profile" 2>/dev/null || true)
    if [ -z "$decoded" ]; then
      bad "cannot decode embedded.mobileprovision"
    else
      # `if`, not `&&`: a non-matching grep as the function's last command would end the script under `set -e`.
      if [ "$dev_archive" = 0 ] && grep -q '<key>ProvisionedDevices</key>' <<<"$decoded"; then
        bad "provisioning profile lists devices (development or ad hoc, not App Store)"
      fi
      if grep -q '<key>ProvisionsAllDevices</key>' <<<"$decoded"; then bad "enterprise provisioning profile"; fi
    fi
  elif [ "$kind" = "ipa" ]; then
    bad "no embedded.mobileprovision in the .ipa app"
  fi
}

# check_app <app> <ipa|archive>
check_app() {
  local app=$1 kind=$2 api appex appex_id
  echo "preflight: checking $app ($kind)"
  check_identity "$app" "$EXPECTED_BUNDLE_ID" "app"
  local app_version=$VERSION_SEEN
  api=$(plist_get "$app/Info.plist" APIBaseURL)
  [ "$api" = "$EXPECTED_API_BASE_URL" ] || bad "APIBaseURL is '$api', expected '$EXPECTED_API_BASE_URL'"
  check_firebase "$app"
  # Placeholder anywhere in the bundle (binaries, strings files, other plists).
  if grep -rlaF "$PLACEHOLDER" "$app" >"$TMP/hits" 2>/dev/null; then
    bad "bundle contains '$PLACEHOLDER' in: $(sed "s|$app/||" "$TMP/hits" | tr '\n' ' ')"
  fi
  # Share extension.
  appex=$(find "$app/PlugIns" -maxdepth 1 -name '*.appex' 2>/dev/null | head -1)
  if [ -z "$appex" ]; then
    bad "no share extension in PlugIns"
  else
    appex_id="$EXPECTED_BUNDLE_ID.share"
    check_identity "$appex" "$appex_id" "share extension"
    [ "$VERSION_SEEN" = "$app_version" ] || bad "share extension version $VERSION_SEEN differs from the app's $app_version"
  fi
  check_signing "$app" "$kind"
  [ -z "$appex" ] || check_signing "$appex" "$kind"
  [ "$FAILED" -ne 0 ] || echo "preflight: $EXPECTED_BUNDLE_ID $app_version"
}

# Locates the .app inside the artifact (extracting an .ipa into $TMP) and runs the checks.
run_preflight() {
  local art=$1 app kind
  [ -e "$art" ] || { echo "preflight: no such file: $art" >&2; exit 2; }
  case "$art" in
    *.xcarchive)
      app=$(find "$art/Products/Applications" -maxdepth 1 -name '*.app' 2>/dev/null | head -1)
      kind=archive ;;
    *.ipa)
      mkdir -p "$TMP/ipa"
      unzip -q -o "$art" -d "$TMP/ipa"
      app=$(find "$TMP/ipa/Payload" -maxdepth 1 -name '*.app' 2>/dev/null | head -1)
      kind=ipa ;;
    *.app)
      app=${art%/}
      kind=ipa ;;
    *) echo "preflight: unsupported artifact (want .xcarchive, .ipa or .app): $art" >&2; exit 2 ;;
  esac
  [ -n "$app" ] && [ -d "$app" ] || { echo "preflight: no .app found in $art" >&2; exit 2; }
  check_app "$app" "$kind"
}

# --- self-test: builds fixture bundles and proves each failure is caught -------------------------------------------
# Optional argument: a built Debug simulator Sroka.app, which must be rejected.
self_test() {
  local real_app=${1:-} fx="$TMP/fx" n=0 failures=0 out rc

  make_app() { # <dir> <bundle id> <version> <api url>
    mkdir -p "$1"
    cat >"$1/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleShortVersionString</key><string>$3</string>
<key>CFBundleVersion</key><string>7</string>
<key>APIBaseURL</key><string>$4</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
</dict></plist>
PLIST
  }
  make_gs() { # <dir> <project id> <bundle id>
    cat >"$1/GoogleService-Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>API_KEY</key><string>AIzaSyRealLooking000000000000000000000</string>
<key>GOOGLE_APP_ID</key><string>1:123456789012:ios:abcdef0123456789</string>
<key>PROJECT_ID</key><string>$2</string>
<key>BUNDLE_ID</key><string>$3</string>
</dict></plist>
PLIST
  }
  # expect_fail <name> <app dir> <substring the failure output must contain>
  expect_fail() {
    n=$((n + 1))
    set +e
    out=$( (FAILED=0; check_app "$2" ipa; exit "$FAILED") 2>&1 )
    rc=$?
    set -e
    if [ "$rc" -ne 0 ] && grep -qF "$3" <<<"$out"; then
      echo "  ok   $1"
    else
      echo "  FAIL $1 (exit $rc, wanted message containing: $3)" >&2
      echo "$out" | sed 's/^/       /' >&2
      failures=$((failures + 1))
    fi
  }

  echo "preflight self-test"
  local a

  a=$fx/no-plist.app; make_app "$a" app.sroka 1.2.3 "$EXPECTED_API_BASE_URL"
  expect_fail "missing GoogleService-Info.plist is rejected" "$a" "no GoogleService-Info.plist"

  a=$fx/placeholder.app; make_app "$a" app.sroka 1.2.3 "$EXPECTED_API_BASE_URL"; make_gs "$a" sroka-example app.sroka
  expect_fail "placeholder Firebase config is rejected" "$a" "is the placeholder"

  a=$fx/wrong-project.app; make_app "$a" app.sroka 1.2.3 "$EXPECTED_API_BASE_URL"; make_gs "$a" other-project app.sroka
  expect_fail "unexpected Firebase project is rejected" "$a" "Firebase PROJECT_ID"

  a=$fx/wrong-bundle.app; make_app "$a" app.sroka.dev 1.2.3 "$EXPECTED_API_BASE_URL"; make_gs "$a" "$EXPECTED_FIREBASE_PROJECT" app.sroka.dev
  expect_fail "unexpected bundle id is rejected" "$a" "bundle id is 'app.sroka.dev'"

  a=$fx/bad-version.app; make_app "$a" app.sroka beta "$EXPECTED_API_BASE_URL"; make_gs "$a" "$EXPECTED_FIREBASE_PROJECT" app.sroka
  expect_fail "malformed version is rejected" "$a" "is not x.y or x.y.z"

  a=$fx/dev-server.app; make_app "$a" app.sroka 1.2.3 http://localhost:8787; make_gs "$a" "$EXPECTED_FIREBASE_PROJECT" app.sroka
  expect_fail "local API base URL is rejected" "$a" "APIBaseURL"

  a=$fx/unsigned.app; make_app "$a" app.sroka 1.2.3 "$EXPECTED_API_BASE_URL"; make_gs "$a" "$EXPECTED_FIREBASE_PROJECT" app.sroka
  expect_fail "unsigned app is rejected" "$a" "ad-hoc signed or unsigned"

  a=$fx/stray.app; make_app "$a" app.sroka 1.2.3 "$EXPECTED_API_BASE_URL"; make_gs "$a" "$EXPECTED_FIREBASE_PROJECT" app.sroka
  printf 'sroka-example' >"$a/stray.txt"
  expect_fail "placeholder string elsewhere in the bundle is rejected" "$a" "bundle contains 'sroka-example'"

  if [ -n "$real_app" ]; then
    [ -d "$real_app" ] || { echo "self-test: no such app: $real_app" >&2; exit 2; }
    expect_fail "built simulator app is rejected" "$real_app" "preflight FAIL"
  fi

  if [ "$failures" -ne 0 ]; then
    echo "preflight self-test: $failures of $n cases FAILED" >&2
    exit 1
  fi
  echo "preflight self-test OK ($n cases)"
  exit 0
}

[ $# -ge 1 ] || usage
TMP=$(mktemp -d "${TMPDIR:-/tmp}/sroka-ios-preflight.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
VERSION_SEEN=

case "$1" in
  --self-test) self_test "${2:-}" ;;
  -h | --help) usage ;;
  *) run_preflight "$1" ;;
esac

if [ "$FAILED" -eq 0 ]; then
  echo "preflight OK: $1"
fi
exit "$FAILED"
