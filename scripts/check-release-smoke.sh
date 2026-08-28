#!/bin/bash
set -euo pipefail

artifact="${1:?usage: check-release-smoke.sh <release-directory>}"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/zeta-release-smoke.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
prefix="$temporary/install"
agent="$temporary/agent"
mkdir -p "$agent"

PREFIX="$prefix" scripts/install.sh "$artifact" >/dev/null
zeta="$prefix/bin/zeta"
pi="$prefix/bin/pi"
test -L "$pi"
test "$(readlink "$pi")" = zeta
"$zeta" --help | grep -q -- '--session-id'
"$pi" --version | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
"$zeta" --list-models=openai | grep -q 'openai'

PI_CODING_AGENT_DIR="$agent" ZETA_FAUX_RESPONSE=print-ok \
  "$zeta" --print hello >"$temporary/print.out"
grep -qx 'print-ok' "$temporary/print.out"

PI_CODING_AGENT_DIR="$agent" ZETA_FAUX_RESPONSE=json-ok \
  "$zeta" --mode json --no-session hello >"$temporary/events.jsonl"
test "$(jq -r 'select(.type=="agent_end") | .type' "$temporary/events.jsonl")" = agent_end

printf '%s\n' '{"id":"rpc-1","type":"prompt","message":"hello"}' \
  | env PI_CODING_AGENT_DIR="$agent" ZETA_FAUX_RESPONSE=rpc-ok \
      "$zeta" --mode rpc --no-session >"$temporary/rpc.jsonl"
test "$(jq -r 'select(.id=="rpc-1") | .success' "$temporary/rpc.jsonl")" = true
test "$(jq -r 'select(.type=="agent_event" and .event.type=="agent_end") | .event.type' "$temporary/rpc.jsonl")" = agent_end

PI_CODING_AGENT_DIR="$agent" ZETA_FAUX_RESPONSE=first \
  "$zeta" --print resume-one >/dev/null
PI_CODING_AGENT_DIR="$agent" ZETA_FAUX_RESPONSE=second \
  "$zeta" --print --continue resume-two >"$temporary/resume.out"
grep -qx second "$temporary/resume.out"
session_count="$(find "$agent/sessions" -name '*.jsonl' -exec wc -l {} + | awk '$2 != "total" && $1 > max { max=$1 } END { print max+0 }')"
test "$session_count" -ge 5

printf '%s\n' '{"id":"export-1","type":"export_html"}' \
  | env PI_CODING_AGENT_DIR="$agent" "$zeta" --mode rpc --continue >"$temporary/export.jsonl"
jq -e 'select(.id=="export-1" and .success==true) | .data.html | contains("Zeta Session")' \
  "$temporary/export.jsonl" >/dev/null

scripts/check-examples.sh >/dev/null
mkdir -p "$agent/plugins/sample/.build/release"
cp Examples/Plugins/AllCapabilitiesPlugin/zeta-plugin.json "$agent/plugins/sample/"
cp Examples/Plugins/AllCapabilitiesPlugin/.build/release/AllCapabilitiesPlugin \
  "$agent/plugins/sample/.build/release/"
PI_CODING_AGENT_DIR="$agent" ZETA_FAUX_TOOL=echo ZETA_FAUX_RESPONSE=plugin-ok \
  "$zeta" --print --no-session plugin >"$temporary/plugin.out"
grep -qx plugin-ok "$temporary/plugin.out"

if command -v script >/dev/null 2>&1; then
  (sleep 1; printf '\003') \
    | env PI_CODING_AGENT_DIR="$agent" ZETA_FAUX_RESPONSE=interactive-ok \
      script -q "$temporary/interactive.log" "$zeta" --no-session interactive \
      >/dev/null 2>"$temporary/interactive.err"
  grep -a -q $'\033\[\?2004l' "$temporary/interactive.log"
  grep -a -q $'\033\[\?25h' "$temporary/interactive.log"
fi
uv run python scripts/check-terminal-signals.py "$zeta" >/dev/null

PREFIX="$prefix" scripts/uninstall.sh >/dev/null
test ! -e "$prefix/bin/zeta"
test ! -e "$prefix/bin/pi"
test ! -e "$prefix/bin/Zeta_ZetaAI.bundle"
echo "isolated release smoke verified"
