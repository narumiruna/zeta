#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tool_versions="$repo_root/.tool-versions"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$tool_versions" ]] || fail ".tool-versions is missing."
swift_pin="$(awk '$1 == "swift" { print $2; exit }' "$tool_versions")"
uv_pin="$(awk '$1 == "uv" { print $2; exit }' "$tool_versions")"
[[ -n "$swift_pin" ]] || fail ".tool-versions does not pin Swift."
[[ -n "$uv_pin" ]] || fail ".tool-versions does not pin uv."

architecture="$(uname -m)"
swift_output="$(swift --version 2>&1)" || fail "unable to read the Swift version."
uv_output="$(uv --version 2>&1)" || fail "unable to read the uv version."

sw_vers
printf '%s\n' "$architecture"
printf '%s\n' "$swift_output"
printf '%s\n' "$uv_output"

[[ "$architecture" == "arm64" ]] || fail "release validation requires arm64, found $architecture."
swift_actual="$(sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' <<<"$swift_output" | head -1)"
[[ -n "$swift_actual" ]] || fail "unable to parse the Swift version."
if [[ "$swift_actual" =~ ^[0-9]+\.[0-9]+$ ]]; then
  swift_actual="$swift_actual.0"
fi
[[ "$swift_actual" == "$swift_pin" ]] || \
  fail "release validation requires Swift $swift_pin, found $swift_actual."
uv_actual="$(awk 'NR == 1 { print $2 }' <<<"$uv_output")"
[[ "$uv_actual" == "$uv_pin" ]] || fail "release validation requires uv $uv_pin, found ${uv_actual:-unknown}."

echo "release environment verified"
