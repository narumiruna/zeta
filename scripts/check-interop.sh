#!/bin/bash
set -euo pipefail

oracle="${PI_ORACLE_ROOT:-/tmp/zeta-pi-baseline-56700d42}"
expected_commit="56700d42ed65a94a80af7376adb19a9298065164"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/zeta-interop.XXXXXX")"
ts_server_pid=""
swift_server_pid=""
cleanup() {
  [[ -z "$ts_server_pid" ]] || kill "$ts_server_pid" 2>/dev/null || true
  [[ -z "$swift_server_pid" ]] || kill "$swift_server_pid" 2>/dev/null || true
  [[ -z "$ts_server_pid" ]] || wait "$ts_server_pid" 2>/dev/null || true
  [[ -z "$swift_server_pid" ]] || wait "$swift_server_pid" 2>/dev/null || true
  rm -rf "$temporary"
}
trap cleanup EXIT

test -d "$oracle"
test "$(git -C "$oracle" rev-parse HEAD)" = "$expected_commit"

typescript_hex="$(node scripts/interop/oracle.mjs "$oracle" protocol)"
expected_hex="00000015a264747970656568656c6c6f6776657273696f6e01"
test "$typescript_hex" = "$expected_hex"
fixture_hex="$(xxd -p Tests/CompatibilityFixtures/v1/protocol/framed-hello.bin | tr -d '\n')"
test "$fixture_hex" = "$expected_hex"

session_result="$(node scripts/interop/oracle.mjs "$oracle" session Tests/CompatibilityFixtures/v1/sessions/coding-agent-v3.jsonl)"
test "$(jq -r '.entries > 0 and .messages > 0' <<<"$session_result")" = true

sqlite_result="$(node scripts/interop/oracle.mjs "$oracle" sqlite Tests/CompatibilityFixtures/v1/sqlite/current-schema.sqlite3)"
test "$(jq -r '.integrity' <<<"$sqlite_result")" = ok
for table in sessions entries lanes records facts writer_leases; do
  test "$(jq --arg table "$table" '.tables | index($table) != null' <<<"$sqlite_result")" = true
done

swift_count="$(jq '[.[]|keys|length]|add' Sources/ZetaAI/Resources/model-catalog.json)"
ts_count="$(jq '[.[]|keys|length]|add' "$oracle/.artifacts/model-catalog/models.json")"
test "$swift_count" = "$ts_count"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcrun swift build >/dev/null
bin_path="$(DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun swift build --show-bin-path)"
interop_database="$temporary/roundtrip.sqlite3"
cp Tests/CompatibilityFixtures/v1/sqlite/current-schema.sqlite3 "$interop_database"
ts_mutation="$(node scripts/interop/oracle.mjs "$oracle" sqlite-mutate "$interop_database")"
test "$(jq -r '.mutated' <<<"$ts_mutation")" = true
swift_sqlite_result="$("$bin_path/zeta-interop-sqlite" "$interop_database")"
test "$(jq -r '.integrity' <<<"$swift_sqlite_result")" = ok
test "$(jq -r '.entries' <<<"$swift_sqlite_result")" = 3
ts_reopen="$(node scripts/interop/oracle.mjs "$oracle" sqlite "$interop_database")"
test "$(jq -r '.integrity' <<<"$ts_reopen")" = ok
test "$(jq -r '.entries' <<<"$ts_reopen")" = 3
"$bin_path/zeta" --help | grep -q -- '--mode'
"$bin_path/pi" --version | grep -q '^0\.1\.0$'
"$bin_path/zeta" --list-models=openai | grep -q 'openai/'

rpc_request='{"id":"interop","type":"get_commands"}'
swift_rpc="$(printf '%s\n' "$rpc_request" | env PI_CODING_AGENT_DIR="$temporary/swift-agent" "$bin_path/zeta" --mode rpc)"
test "$(jq -r 'select(.id=="interop") | .success' <<<"$swift_rpc")" = true

temporary_home="$temporary/home"
mkdir -p "$temporary_home"
ts_rpc="$(printf '%s\n' "$rpc_request" | env HOME="$temporary_home" PI_OFFLINE=1 \
  node "$oracle/packages/coding-agent/dist/bundle/cli.js" --mode rpc 2>/dev/null)"
test "$(jq -r 'select(.id=="interop") | .success' <<<"$ts_rpc")" = true

ts_socket="$temporary/typescript.sock"
node scripts/interop/oracle.mjs "$oracle" serve "$ts_socket" >"$temporary/typescript-server.log" 2>&1 &
ts_server_pid=$!
for _ in {1..200}; do [[ -S "$ts_socket" ]] && break; sleep 0.01; done
test -S "$ts_socket"
swift_client_result="$("$bin_path/zeta-interop-client" "$ts_socket")"
test "$(jq -r '.sessions' <<<"$swift_client_result")" = 0
kill "$ts_server_pid"
wait "$ts_server_pid" || true
ts_server_pid=""

swift_socket="$temporary/swift.sock"
"$bin_path/zeta-interop-server" "$swift_socket" >"$temporary/swift-server.log" 2>&1 &
swift_server_pid=$!
for _ in {1..200}; do [[ -S "$swift_socket" ]] && break; sleep 0.01; done
test -S "$swift_socket"
ts_client_result="$(node scripts/interop/oracle.mjs "$oracle" client "$swift_socket")"
test "$(jq -r '.initialSessions' <<<"$ts_client_result")" = 0
test "$(jq -r '.sessions' <<<"$ts_client_result")" = 1
test "$(jq -r '.transcript' <<<"$ts_client_result")" = 1
test "$(jq -r '.attached' <<<"$ts_client_result")" = true
kill "$swift_server_pid"
wait "$swift_server_pid" || true
swift_server_pid=""

echo "interop verified: protocol, both client/server directions, create/prompt/detach, sessions, TypeScript-to-Swift-to-TypeScript SQLite mutation, catalog, CLI, and RPC at $expected_commit"
