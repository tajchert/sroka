#!/usr/bin/env bash
# One entry point for formatting, tests and builds. See AGENTS.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_NAME="${SIM_NAME:-iPhone 18 Pro}"
SIM_OS="${SIM_OS:-27.2}"
DESTINATION="platform=iOS Simulator,name=${SIM_NAME},OS=${SIM_OS}"

# Keep this list in sync with new source directories.
FORMAT_PATHS=(App Share UITests Modules/Sources Modules/Tests Modules/Package.swift)

usage() {
    cat <<EOF
Usage: scripts/verify.sh <command> [args]

Commands:
  format               Lint Swift sources with swift-format (strict); non-zero on any finding
  format-fix           Rewrite Swift sources in place with swift-format
  unit [TestTarget...] Package unit + snapshot tests (all targets, or only the named ones)
  build [Dev|Prod]     Build the app for the simulator (default: Dev)
  ui                   UI tests (SrokaUITests) on the simulator destination
  all                  format, unit, build Dev, build Prod (no UI tests)
  help                 Show this text

Environment:
  SIM_NAME   Simulator name (default: iPhone 18 Pro)
  SIM_OS     Simulator OS version (default: 27.2)
  Snapshot references are only valid on iPhone 18 Pro / iOS 27.2.
EOF
}

cmd_format() {
    cd "$ROOT"
    xcrun swift-format lint --strict --recursive "${FORMAT_PATHS[@]}"
}

cmd_format_fix() {
    cd "$ROOT"
    xcrun swift-format format --in-place --recursive "${FORMAT_PATHS[@]}"
}

cmd_unit() {
    cd "$ROOT/Modules"
    local only=()
    local target
    for target in "$@"; do
        only+=("-only-testing:${target}")
    done
    xcodebuild test -quiet -scheme Modules-Package -destination "$DESTINATION" ${only[@]+"${only[@]}"}
}

cmd_build() {
    local env="${1:-Dev}"
    case "$env" in
        Dev | Prod) ;;
        *)
            echo "error: unknown environment '$env' (expected Dev or Prod)" >&2
            exit 2
            ;;
    esac
    cd "$ROOT"
    xcodebuild build -quiet -project Sroka.xcodeproj -scheme "Sroka ${env}" \
        -destination 'generic/platform=iOS Simulator'
}

cmd_ui() {
    cd "$ROOT"
    xcodebuild test -quiet -project Sroka.xcodeproj -scheme "Sroka Dev" \
        -destination "$DESTINATION" -only-testing:SrokaUITests
}

cmd_all() {
    cmd_format
    cmd_unit
    cmd_build Dev
    cmd_build Prod
}

command="${1:-help}"
[[ $# -gt 0 ]] && shift

case "$command" in
    format) cmd_format ;;
    format-fix) cmd_format_fix ;;
    unit) cmd_unit "$@" ;;
    build) cmd_build "$@" ;;
    ui) cmd_ui ;;
    all) cmd_all ;;
    help | -h | --help) usage ;;
    *)
        echo "error: unknown command '$command'" >&2
        usage >&2
        exit 2
        ;;
esac
