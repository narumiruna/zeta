#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
consumer_root="$root/Examples/iOSLibraryConsumer"
if ! command -v uv >/dev/null 2>&1; then
  echo "FAIL: required command is unavailable: uv" >&2
  exit 1
fi
artifacts_input="${ZETA_IOS_ARTIFACTS_DIR:-/tmp/zeta-ios-libraries}"
if [[ "$artifacts_input" != /* ]]; then
  artifacts_input="$root/$artifacts_input"
fi
artifacts_dir="$(
  uv run python "$root/scripts/ios_library_check_support.py" \
    prepare-artifacts "$artifacts_input" "$root"
)"
derived_root="$(mktemp -d "${TMPDIR:-/tmp}/zeta-ios-libraries-derived.XXXXXX")"
trap 'rm -rf "$derived_root"' EXIT

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

for command in swift xcodebuild xcrun; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "FAIL: required command is unavailable: $command" >&2
    exit 1
  fi
done

run_logged() {
  local name="$1"
  shift
  local log="$artifacts_dir/$name.log"
  echo "Running $name"
  if "$@" >"$log" 2>&1; then
    echo "PASS: $name"
  else
    local status=$?
    echo "FAIL: $name (diagnostics: $log)" >&2
    tail -n 200 "$log" >&2 || true
    return "$status"
  fi
}

(
  cd "$root"
  swift package dump-package >"$artifacts_dir/package.json"
)
(
  cd "$consumer_root"
  swift package describe --type json >"$artifacts_dir/consumer-package.json"
)
uv run python "$root/scripts/check-package-dependencies.py" \
  --manifest "$artifacts_dir/package.json" \
  --resolved "$root/Package.resolved"
uv run python - "$artifacts_dir/package.json" "$artifacts_dir/consumer-package.json" <<'PY'
import json
import sys
from pathlib import Path

package = json.loads(Path(sys.argv[1]).read_text())
platforms = {item["platformName"]: item["version"] for item in package["platforms"]}
if platforms != {"macos": "14.0", "ios": "17.0"}:
    raise SystemExit(f"unexpected package platforms: {platforms}")
expected_dependencies = {
    "swift-argument-parser": (
        "https://github.com/apple/swift-argument-parser.git",
        "exact",
        "1.8.2",
    ),
    "swift-log": (
        "https://github.com/apple/swift-log.git",
        "exact",
        "1.9.1",
    ),
}
dependencies = {}
for dependency in package["dependencies"]:
    source_control = dependency.get("sourceControl", [])
    if len(source_control) != 1:
        raise SystemExit(f"unexpected dependency declaration: {dependency}")
    declaration = source_control[0]
    remotes = declaration["location"].get("remote", [])
    requirement = declaration["requirement"]
    if len(remotes) != 1 or len(requirement) != 1:
        raise SystemExit(f"invalid dependency declaration: {declaration['identity']}")
    requirement_kind, requirement_values = next(iter(requirement.items()))
    if requirement_kind not in {"exact", "revision"} or len(requirement_values) != 1:
        raise SystemExit(f"dependency is not pinned immutably: {declaration['identity']}")
    dependencies[declaration["identity"]] = (
        remotes[0]["urlString"],
        requirement_kind,
        requirement_values[0],
    )
if dependencies != expected_dependencies:
    raise SystemExit(f"unexpected root dependencies: {dependencies}")
products = {item["name"]: item["type"] for item in package["products"]}
for name in ("ZetaAI", "ZetaAgent"):
    if products.get(name) != {"library": ["automatic"]}:
        raise SystemExit(f"unexpected {name} product declaration: {products.get(name)}")

consumer = json.loads(Path(sys.argv[2]).read_text())
if consumer["platforms"] != [{"name": "ios", "version": "17.0"}]:
    raise SystemExit(f"unexpected consumer platforms: {consumer['platforms']}")
for target in consumer["targets"]:
    dependencies = set(target.get("product_dependencies", []))
    if dependencies != {"ZetaAI", "ZetaAgent"}:
        raise SystemExit(
            f"unexpected Zeta product selection for {target['name']}: {sorted(dependencies)}"
        )
print("PASS: iOS manifest and external-consumer contracts")
PY

{
  sw_vers
  uname -m
  xcodebuild -version
  swift --version
  uv --version
  xcrun --sdk iphoneos --show-sdk-version
  xcrun --sdk iphonesimulator --show-sdk-version
} >"$artifacts_dir/environment.txt" 2>&1

common_build_settings=(
  CODE_SIGNING_ALLOWED=NO
  COMPILER_INDEX_STORE_ENABLE=NO
  GCC_TREAT_WARNINGS_AS_ERRORS=YES
  SWIFT_STRICT_CONCURRENCY=complete
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
)

(
  cd "$root"
  run_logged iphoneos-zeta-ai xcodebuild -quiet \
    -scheme ZetaAI \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$derived_root/device" \
    "${common_build_settings[@]}" \
    build
  run_logged iphoneos-zeta-agent xcodebuild -quiet \
    -scheme ZetaAgent \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$derived_root/device" \
    "${common_build_settings[@]}" \
    build
)

(
  cd "$root"
  run_logged iphonesimulator-zeta-ai xcodebuild -quiet \
    -scheme ZetaAI \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$derived_root/simulator" \
    "${common_build_settings[@]}" \
    build
  run_logged iphonesimulator-zeta-agent xcodebuild -quiet \
    -scheme ZetaAgent \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$derived_root/simulator" \
    "${common_build_settings[@]}" \
    build
)

(
  cd "$consumer_root"
  run_logged iphonesimulator-consumer-build xcodebuild -quiet \
    -scheme ZetaIOSLibraryConsumer \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$derived_root/consumer-build" \
    CODE_SIGNING_ALLOWED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    SWIFT_STRICT_CONCURRENCY=complete \
    build
)

xcrun simctl list devices available -j >"$artifacts_dir/simulators-before.json"
simulator_record="$(
  uv run python "$root/scripts/ios_library_check_support.py" \
    select-simulator "$artifacts_dir/simulators-before.json" \
    --minimum 17.0
)"
IFS=$'\t' read -r simulator_udid simulator_initial_state simulator_name <<<"$simulator_record"
if [[ -z "$simulator_udid" || -z "$simulator_initial_state" ]]; then
  echo "FAIL: simulator selection returned an invalid record" >&2
  exit 1
fi
printf 'Selected simulator: %s (%s), initial state: %s\n' \
  "$simulator_name" "$simulator_udid" "$simulator_initial_state" \
  >"$artifacts_dir/simulator-selection.txt"
cat "$artifacts_dir/simulator-selection.txt"

booted_by_script=0
cleanup() {
  local status=$?
  trap - EXIT
  rm -rf "$derived_root"
  if [[ "$booted_by_script" -eq 1 ]]; then
    if xcrun simctl shutdown "$simulator_udid" >>"$artifacts_dir/simulator-cleanup.log" 2>&1; then
      echo "Restored simulator to Shutdown" >>"$artifacts_dir/simulator-cleanup.log"
    else
      echo "FAIL: could not restore simulator state" >&2
      status=1
    fi
  fi
  xcrun simctl list devices available -j >"$artifacts_dir/simulators-after.json" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT

if [[ "$simulator_initial_state" = "Shutdown" ]]; then
  run_logged simulator-boot xcrun simctl boot "$simulator_udid"
  booted_by_script=1
  run_logged simulator-boot-status xcrun simctl bootstatus "$simulator_udid" -b
fi

result_bundle="$artifacts_dir/ios-consumer-tests.xcresult"
(
  cd "$consumer_root"
  run_logged ios-consumer-tests xcodebuild -quiet \
    -scheme ZetaIOSLibraryConsumer \
    -destination "platform=iOS Simulator,id=$simulator_udid" \
    -derivedDataPath "$derived_root/consumer-tests" \
    -resultBundlePath "$result_bundle" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    SWIFT_STRICT_CONCURRENCY=complete \
    test
)

xcrun xcresulttool get test-results summary \
  --path "$result_bundle" \
  --format json >"$artifacts_dir/test-summary.json"
uv run python - "$artifacts_dir/test-summary.json" <<'PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text())
total = summary.get("totalTestCount")
passed = summary.get("passedTests")
failed = summary.get("failedTests")
skipped = summary.get("skippedTests")
expected_failures = summary.get("expectedFailures")
if (total, passed, failed, skipped, expected_failures) != (2, 2, 0, 0, 0):
    raise SystemExit(
        "unexpected iOS test summary: "
        f"total={total}, passed={passed}, failed={failed}, skipped={skipped}, "
        f"expectedFailures={expected_failures}"
    )
print("PASS: 2 iOS consumer tests, 0 failures, 0 skips")
PY

echo "iOS library checks passed (artifacts: $artifacts_dir)"
