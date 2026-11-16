#!/usr/bin/env bash
# Release preflight for an Android artifact: usage scripts/release-preflight.sh <artifact.apk|aab>
# Fails if the artifact embeds the placeholder Firebase project (sroka-example) or is not
# signed with a non-debug certificate. Needs unzip, grep, and apksigner (APK) / jarsigner (AAB).
set -euo pipefail

ART=${1:?usage: release-preflight.sh <artifact.apk|aab>}
[ -f "$ART" ] || { echo "preflight: no such file: $ART" >&2; exit 2; }
ANDROID_HOME=${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}
JAVA_HOME=${JAVA_HOME:-$(/usr/libexec/java_home -v 21 2>/dev/null || true)}
[ -n "$JAVA_HOME" ] && PATH="$JAVA_HOME/bin:$PATH"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sroka-preflight.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
FAILED=0
bad() { echo "preflight FAIL: $*" >&2; FAILED=1; }

# 1. Placeholder Firebase config (matches plain UTF-8/ASCII and UTF-16LE strings).
unzip -q -o "$ART" -d "$TMP/x"
if grep -rlaF 'sroka-example' "$TMP/x" >"$TMP/hits" 2>/dev/null \
  || LC_ALL=C grep -rlaP 's\x00r\x00o\x00k\x00a\x00-\x00e\x00x\x00a\x00m\x00p\x00l\x00e' "$TMP/x" >"$TMP/hits" 2>/dev/null; then
  bad "artifact contains 'sroka-example' (placeholder Firebase config) in: $(sed "s|$TMP/x/||" "$TMP/hits" | tr '\n' ' ')"
fi

# 2. Signing: must be signed, and not by the Android debug cert.
case "$ART" in
  *.apk)
    APKSIGNER=$(find "$ANDROID_HOME/build-tools" -name apksigner -type f 2>/dev/null | sort -V | tail -n1)
    [ -n "$APKSIGNER" ] || { echo "preflight: apksigner not found under \$ANDROID_HOME/build-tools" >&2; exit 2; }
    OUT=$("$APKSIGNER" verify --print-certs "$ART" 2>&1) || { bad "apksigner verify failed: $OUT"; OUT=; }
    ;;
  *.aab)
    OUT=$(jarsigner -verify -verbose -certs "$ART" 2>&1) || true
    grep -q 'jar verified' <<<"$OUT" || bad "jarsigner: AAB is unsigned or does not verify"
    ;;
  *) echo "preflight: unsupported artifact (want .apk or .aab): $ART" >&2; exit 2 ;;
esac
grep -Eq 'CN=Android Debug' <<<"$OUT" && bad "signed with the Android debug certificate"
grep -E 'Signer #1 certificate (DN|SHA-256)|CN=' <<<"$OUT" | sort -u | head -3 || true

[ "$FAILED" -eq 0 ] && echo "preflight OK: $ART"
exit "$FAILED"
