#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tool_versions="$repo_root/.tool-versions"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

swift_version_token() {
  sed -nE 's/.*Swift version ([^[:space:]]+).*/\1/p' <<<"$1" | head -1
}

require_swift_pin() {
  local name="$1"
  local output="$2"
  local actual
  actual="$(swift_version_token "$output")"
  [[ -n "$actual" ]] || fail "unable to parse the $name version."
  if [[ "$actual" != "$swift_pin" && "$actual" != "$swift_alias" ]]; then
    fail "release validation requires $name $swift_pin, found $actual."
  fi
}

[[ -f "$tool_versions" ]] || fail ".tool-versions is missing."
swift_pin="$(awk '$1 == "swift" { print $2; exit }' "$tool_versions")"
uv_pin="$(awk '$1 == "uv" { print $2; exit }' "$tool_versions")"
[[ -n "$swift_pin" ]] || fail ".tool-versions does not pin Swift."
[[ -n "$uv_pin" ]] || fail ".tool-versions does not pin uv."
swift_alias="$swift_pin"
if [[ "$swift_pin" == *.0 ]]; then
  swift_alias="${swift_pin%.0}"
fi

checkout_status="$(git -C "$repo_root" status --porcelain --untracked-files=all)"
ignored_inputs="$(
  git -C "$repo_root" ls-files --others --ignored --exclude-standard -- \
    Sources Tests Examples docs
)"
if [[ -n "$checkout_status" || -n "$ignored_inputs" ]]; then
  fail "release validation requires a clean checkout without ignored release inputs."
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

architecture="$(uname -m)"
swift_output="$(swift --version 2>&1)" || fail "unable to read the PATH Swift version."
xcode_swift_output="$(xcrun swift --version 2>&1)" || fail "unable to read the Xcode Swift version."
xcode_output="$(xcodebuild -version 2>&1)" || fail "unable to read the Xcode version."
uv_output="$(uv --version 2>&1)" || fail "unable to read the uv version."

sw_vers
printf '%s\n' "$architecture"
printf '%s\n' "$swift_output"
printf '%s\n' "$xcode_swift_output"
printf '%s\n' "$xcode_output"
printf '%s\n' "$uv_output"

[[ "$architecture" == "arm64" ]] || fail "release validation requires arm64, found $architecture."
require_swift_pin "PATH Swift" "$swift_output"
require_swift_pin "Xcode Swift" "$xcode_swift_output"
uv_actual="$(awk 'NR == 1 { print $2 }' <<<"$uv_output")"
[[ "$uv_actual" == "$uv_pin" ]] || fail "release validation requires uv $uv_pin, found ${uv_actual:-unknown}."

echo "release environment verified"
