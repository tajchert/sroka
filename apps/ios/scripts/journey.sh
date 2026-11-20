#!/usr/bin/env bash
# Live-backend journeys: the Dev app (no -UITests fakes) against a local `wrangler dev`. Starts nothing but a tiny
# TCP proxy (so the offline journey can cut the network); the stack must already run (workers/api/CLAUDE.md "Local stack").
#
#   DEV_LOG=/path/to/wrangler.log SIM_NAME=sroka-q apps/ios/scripts/journey.sh [--direct] [TestName ...]
#
# Env:  DEV_LOG       wrangler dev log (required; sign-in codes are read from it)
#       SERVER_PORT   port of wrangler dev (default 8787)
#       PROXY_PORT    port of the proxy the app talks to (default 8788)
#       SIM_NAME/SIM_OS  simulator (default iPhone 18 Pro / 27.2); a booted copy is created if shut down
#       TIME_LIMIT    seconds for the whole xcodebuild run (default 900)
#       OUT_DIR       screenshots (default apps/ios/docs/shots/journeys)
# The app is uninstalled from the simulator on every run (fresh install, signed out): use your own, SIM_NAME must start with 'sroka-'.
# --direct: no proxy, the app uses the Dev build default server (http://localhost:8787); the offline journey skips.
# TestName: a test method (e.g. testB_SaveAndRead) or class/method; default = all journeys in SrokaJourneyTests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_PORT="${SERVER_PORT:-8787}"
PROXY_PORT="${PROXY_PORT:-8788}"
SIM_NAME="${SIM_NAME:-iPhone 18 Pro}"
SIM_OS="${SIM_OS:-27.2}"
TIME_LIMIT="${TIME_LIMIT:-900}"
OUT_DIR="${OUT_DIR:-$ROOT/docs/shots/journeys}"
DEV_LOG="${DEV_LOG:?set DEV_LOG to the wrangler dev log (sign-in codes are read from it)}"
DIRECT=0
TESTS=()
for arg in "$@"; do
    case "$arg" in
        --direct) DIRECT=1 ;;
        *) TESTS+=("$arg") ;;
    esac
done

curl -fsS -m 5 "http://localhost:${SERVER_PORT}/v1/health" >/dev/null ||
    { echo "error: no server on :${SERVER_PORT} (start: npm run dev -w @sroka/api > \$DEV_LOG)" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sroka-journey.XXXXXX")"
RESULT="$WORK/result.xcresult"
LOG="$WORK/xcodebuild.log"
CONTROL="$WORK/net"
echo up >"$CONTROL"
PROXY_PID=""
XCB_PID=""
cleanup() {
    [[ -n "$PROXY_PID" ]] && kill "$PROXY_PID" 2>/dev/null || true
    if [[ -n "$XCB_PID" ]]; then
        pkill -P "$XCB_PID" 2>/dev/null || true
        kill "$XCB_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

SERVER_URL=""
if [[ $DIRECT -eq 0 ]]; then
    node "$ROOT/scripts/journey-proxy.mjs" "$PROXY_PORT" "$SERVER_PORT" "$CONTROL" >"$WORK/proxy.log" 2>&1 &
    PROXY_PID=$!
    SERVER_URL="http://127.0.0.1:${PROXY_PORT}"
fi

# The simulator: fresh install every run (no keychain or database from an earlier run).
UDID="$(xcrun simctl list devices available -j | node -e '
const name = process.argv[1];
const d = JSON.parse(require("fs").readFileSync(0, "utf8")).devices;
for (const list of Object.values(d)) for (const s of list) if (s.name === name) { console.log(s.udid); process.exit(0); }
' "$SIM_NAME")"
[[ -n "$UDID" ]] || { echo "error: no simulator named '$SIM_NAME'" >&2; exit 1; }
[[ "$SIM_NAME" == sroka-* ]] ||
    { echo "error: the journeys uninstall the app from the simulator; use your own one (xcrun simctl create sroka-<stream> \"iPhone 18 Pro\")" >&2; exit 1; }
# Only uninstall: the app clears an earlier install's Keychain session on its first launch, so a reinstall starts signed
# out (journey a asserts it). Use a simulator made for the journeys (SIM_NAME=sroka-<stream>).
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" app.sroka.dev 2>/dev/null || true
# A full run starts from an empty screenshot folder; a run of selected tests only replaces its own shots.
[[ ${#TESTS[@]} -eq 0 ]] && rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

ONLY=()
if [[ ${#TESTS[@]} -eq 0 ]]; then
    ONLY=("-only-testing:SrokaUITests/SrokaJourneyTests")
else
    for t in "${TESTS[@]}"; do
        [[ "$t" == */* ]] && ONLY+=("-only-testing:SrokaUITests/$t") || ONLY+=("-only-testing:SrokaUITests/SrokaJourneyTests/$t")
    done
fi

EMAIL="journey-$(date +%s)-$RANDOM@example.com"
cd "$ROOT"
# TEST_RUNNER_ variables reach the test process without the prefix.
env \
    TEST_RUNNER_SROKA_DEV_LOG="$DEV_LOG" \
    TEST_RUNNER_SROKA_SERVER_URL="$SERVER_URL" \
    TEST_RUNNER_SROKA_NET_CONTROL="$CONTROL" \
    TEST_RUNNER_SROKA_JOURNEY_EMAIL="$EMAIL" \
    TEST_RUNNER_SROKA_SHOTS_DIR="$OUT_DIR" \
    TEST_RUNNER_SROKA_ARTICLE_URL="${SROKA_ARTICLE_URL:-}" \
    xcodebuild test -project Sroka.xcodeproj -scheme "Sroka Dev" \
    -destination "platform=iOS Simulator,id=$UDID" -resultBundlePath "$RESULT" "${ONLY[@]}" >"$LOG" 2>&1 &
XCB_PID=$!

# The UI test runner can stall after printing results: stop waiting once the summary is in, or at the time limit.
START=$SECONDS
while kill -0 "$XCB_PID" 2>/dev/null; do
    if grep -qE "^\*\* TEST (SUCCEEDED|FAILED) \*\*" "$LOG"; then break; fi
    if grep -qE "Test Suite '(Selected tests|All tests)' (passed|failed)" "$LOG"; then sleep 5; break; fi
    if (( SECONDS - START > TIME_LIMIT )); then echo "error: time limit ${TIME_LIMIT}s reached" >&2; break; fi
    sleep 3
done
pkill -P "$XCB_PID" 2>/dev/null || true
kill "$XCB_PID" 2>/dev/null || true
wait "$XCB_PID" 2>/dev/null || true
XCB_PID=""

grep -E "Test Case '.*' (passed|failed)|error:|Executed [0-9]+ test|\*\* TEST" "$LOG" | tail -40 || true
# Screenshots attached to the result bundle (the tests also write PNGs into OUT_DIR directly).
if [[ -d "$RESULT" ]]; then
    xcrun xcresulttool export attachments --path "$RESULT" --output-path "$WORK/attachments" >/dev/null 2>&1 || true
fi
echo "log: $LOG  result: $RESULT  shots: $OUT_DIR"
grep -qE "^\*\* TEST SUCCEEDED \*\*" "$LOG"
