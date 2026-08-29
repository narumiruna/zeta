#!/bin/bash
set -euo pipefail

if [[ ! -f Package.swift ]]; then
  echo "SKIP Swift format, lint, API, build, test, and strict-concurrency gates: Package.swift is absent."
  exit 0
fi

if [[ -z "${DEVELOPER_DIR:-}" && -z "${ZETA_SWIFT_TOOLCHAIN_CONFIGURED:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if swift format --help >/dev/null 2>&1; then
  swift format lint --strict --recursive Sources Tests
else
  echo "FAIL: the pinned Swift toolchain must provide swift-format."
  exit 1
fi

swift package dump-package >/dev/null
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

api_baseline="${ZETA_API_BASELINE:-}"
if [[ -n "$api_baseline" ]]; then
  swift package diagnose-api-breaking-changes "$api_baseline"
elif git rev-parse --verify HEAD^:Package.swift >/dev/null 2>&1; then
  swift package diagnose-api-breaking-changes HEAD^
else
  echo "SKIP API breakage comparison: no committed Package.swift baseline exists."
fi
