#!/usr/bin/env bash
# Build, preflight and upload the Android app (play flavor) to a Google Play testing track.
#
#   scripts/release/android.sh --check          # credentials + app access only, no build
#   scripts/release/android.sh                  # bundlePlayRelease -> preflight -> internal track
#   scripts/release/android.sh --track alpha    # closed testing (track names: internal, alpha, beta, or a custom one)
#   scripts/release/android.sh --draft          # create the release as a draft (needed while the app is unpublished)
#   scripts/release/android.sh --skip-build     # upload the bundle already in app/build/outputs
#   scripts/release/android.sh --notes FILE     # en-US release notes (default: store/google-play/release-notes/<versionCode>.txt if present)
#   scripts/release/android.sh --github-release [--github-notes FILE]
#                                               # also build the play APK and publish GitHub release android-v<versionName>
#                                               #   with sroka-<versionName>-release.apk; notes default to the Play notes
#
# Production is never touched: promote the tested release in Play Console.
# Credentials: $CREDS_DIR/play-service-account.json (docs/releasing.md, "Google Play").
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PACKAGE=app.sroka
TRACK=internal STATUS=completed CHECK=0 BUILD=1 NOTES= GH=0 GH_NOTES=
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --track) TRACK=${2:?--track needs a value}; shift ;;
    --draft) STATUS=draft ;;
    --skip-build) BUILD=0 ;;
    --notes) NOTES=${2:?--notes needs a file}; shift ;;
    --github-release) GH=1 ;;
    --github-notes) GH_NOTES=${2:?--github-notes needs a file}; shift ;;
    *) die "unknown option $1 (see header of $0)" ;;
  esac
  shift
done

require_cmd node
KEY=$(creds_file play-service-account.json)

if [ "$CHECK" = 1 ]; then
  node "$REPO_ROOT/scripts/release/play-upload.mjs" --key "$KEY" --package "$PACKAGE" --check
  exit
fi

ANDROID_DIR="$REPO_ROOT/apps/android"
export ANDROID_HOME=${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}
export JAVA_HOME=${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}
AAB="$ANDROID_DIR/app/build/outputs/bundle/playRelease/app-play-release.aab"
APK="$ANDROID_DIR/app/build/outputs/apk/play/release/app-play-release.apk"
MAPPING="$ANDROID_DIR/app/build/outputs/mapping/playRelease/mapping.txt"

VERSION_CODE=$(sed -nE 's/^[[:space:]]*versionCode = ([0-9]+).*/\1/p' "$ANDROID_DIR/app/build.gradle.kts" | head -1)
VERSION_NAME=$(sed -nE 's/^[[:space:]]*versionName = "([^"]+)".*/\1/p' "$ANDROID_DIR/app/build.gradle.kts" | head -1)
DEFAULT_NOTES="$REPO_ROOT/store/google-play/release-notes/$VERSION_CODE.txt"
[ -z "$NOTES" ] && [ -f "$DEFAULT_NOTES" ] && NOTES=$DEFAULT_NOTES
TAG="android-v$VERSION_NAME"
if [ "$GH" = 1 ]; then
  [ -z "$GH_NOTES" ] && GH_NOTES=$NOTES
  [ -n "$GH_NOTES" ] || die "--github-release needs --github-notes FILE (or Play notes in $DEFAULT_NOTES)"
  gh_release_preflight "$TAG"
fi

if [ "$BUILD" = 1 ]; then
  require_clean_tree
  [ -f "$ANDROID_DIR/keystore.properties" ] || [ -n "${SROKA_KEYSTORE_PATH:-}" ] \
    || die "no release keystore (apps/android/keystore.properties or SROKA_KEYSTORE_*)"
  tasks=(:app:bundlePlayRelease)
  [ "$GH" = 1 ] && tasks+=(:app:assemblePlayRelease)
  step "${tasks[*]}"
  (cd "$ANDROID_DIR" && ./gradlew --quiet "${tasks[@]}")
fi
[ -f "$AAB" ] || die "no bundle at $AAB"

step "preflight"
"$REPO_ROOT/scripts/release-preflight.sh" "$AAB"
if [ "$GH" = 1 ]; then
  [ -f "$APK" ] || die "no APK at $APK"
  "$REPO_ROOT/scripts/release-preflight.sh" "$APK"
fi

# Keep the exact uploaded artifact and its mapping (store/upload/ is gitignored).
mkdir -p "$REPO_ROOT/store/upload"
cp "$AAB" "$REPO_ROOT/store/upload/sroka-$VERSION_NAME-$VERSION_CODE.aab"
[ -f "$MAPPING" ] && cp "$MAPPING" "$REPO_ROOT/store/upload/sroka-$VERSION_NAME-$VERSION_CODE-mapping.txt"

step "upload $VERSION_NAME ($VERSION_CODE) to '$TRACK'"
args=(--key "$KEY" --package "$PACKAGE" --aab "$AAB" --track "$TRACK" --status "$STATUS")
[ -f "$MAPPING" ] && args+=(--mapping "$MAPPING")
[ -n "$NOTES" ] && args+=(--notes "$NOTES")
node "$REPO_ROOT/scripts/release/play-upload.mjs" "${args[@]}"

if [ "$GH" = 1 ]; then
  ASSET="$REPO_ROOT/store/upload/sroka-$VERSION_NAME-release.apk"
  cp "$APK" "$ASSET"
  BODY="$REPO_ROOT/store/upload/github-$TAG.md"
  release_body "$BODY" "Sroka Android $VERSION_NAME ($VERSION_CODE)" "$GH_NOTES" \
    "Install: download \`sroka-$VERSION_NAME-release.apk\` and install over the previous version (same release key, SHA-256 \`74ee30adc67a9c03be7d329d6d68154f1ca75ecba6ef13914c6923536863f74a\`)."
  gh_release_create "$TAG" "Sroka Android $VERSION_NAME" "$BODY" "$ASSET"
fi
echo "commit: $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
