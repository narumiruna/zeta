# Pull request 1 follow-up review ledger

This document continues the [primary ledger](2026-08-28_pr-1-review-ledger.md).

## Sixth-round inline feedback

### `3885690935`

Concern: Plugin stdin writes can block the host actor before timeout handling starts.

Outcome: Addressed with nonisolated asynchronous writes covered by shared timeout, cancellation, and process-tree termination.

Evidence: Plugin regressions cover blocked writes, timeout, caller cancellation, and explicit stop.

### `3885690937`

Concern: A stored Vertex bearer credential overrides an explicit API key.

Outcome: Addressed by applying explicit request and CLI keys before stored bearer selection.

Evidence: `testExplicitVertexKeysOverrideStoredBearerTokens` verifies header mode and precedence.

### `3885690939`

Concern: Cancelled grep and find operations leave subprocesses running.

Outcome: Addressed with asynchronous draining and process-group termination on cancellation.

Evidence: Search regressions capture child PIDs and verify prompt process exit.

### `3885690943`

Concern: Failed settings persistence publishes the rejected candidate in memory.

Outcome: Addressed by mutating and persisting a copy before assigning live actor state.

Evidence: `testFailedSettingsModificationDoesNotPublishCandidate` verifies current state and disk remain unchanged.

### `3885690945`

Concern: Case-folded search indexes can be invalid in the original Unicode string.

Outcome: Addressed with case-insensitive range lookup that returns indexes in the original string.

Evidence: Unicode search regression covers repeated Turkish `İ` before the match.

### `3885690947`

Concern: Client handshake waits are unbounded and ignore cancellation.

Outcome: Addressed with a configurable five-second default timeout, cancellation cleanup, and exactly-once transport closure.

Evidence: Client regressions cover timeout, cancellation, late hello, and retry races.

### `3885690950`

Concern: Unix socket closure races queued writes and descriptor reuse.

Outcome: Addressed by serializing descriptor closure with writes and rechecking closed state on the write queue.

Evidence: Unix transport regressions verify queued sends settle as closed before descriptor closure.

### `3885690953`

Concern: Minimum-expiry parsing and deadline addition can overflow.

Outcome: Addressed with checked unit multiplication and checked timestamp addition.

Evidence: CLI regression covers raw and suffixed `Int64` overflow values.

### `3885690955`

Concern: Shell execution stores unbounded output in memory.

Outcome: Addressed by incremental file spooling, bounded tail retention, and throttled bounded progress snapshots.

Evidence: Shell regression emits output beyond the limits and verifies full spool content plus bounded memory-facing results.

### `3885690957`

Concern: Editor wrapping strips the cursor marker and cursor style.

Outcome: Addressed by preserving only cursor marker controls through wrapping while ordinary ANSI controls retain existing stripping semantics.

Evidence: Focused-editor and compatibility regressions verify cursor presence and normal stripped output.

### `3885690960`

Concern: Provider-controlled content indexes can trap or allocate without bound.

Outcome: Addressed by rejecting indexes outside `0...4095` before any mutation or allocation.

Evidence: Provider regressions cover negative and oversized Anthropic, Responses, and Chat indexes.

## Seventh-round inline feedback

### `3885744293`

Concern: Concurrent RPC task creation can reorder stdin admission.

Outcome: Addressed by serializing record admission into `CLIRPCRuntime` while accepted long-running effects remain concurrent.

Evidence: RPC regressions verify ordered prompts and concurrent bash abort.

### `3885744295`

Concern: Distinct provider tool-call IDs can collide after normalization.

Outcome: Addressed with stable collision tracking and deterministic SHA-256 suffixes shared by calls and results.

Evidence: Transform regression covers `call.a` and `calla` with correctly paired results.

### `3885744299`

Concern: Oversized credential helper output fails without terminating the helper.

Outcome: Addressed by closing the pipe and terminating the process group on output-limit failure.

Evidence: AuthStore regression verifies the helper and child process exit.

### `3885744302`

Concern: Failed dynamic-catalog persistence publishes uncommitted models.

Outcome: Addressed by persisting the fetched catalog before changing `currentModels` and by transactional file-store writes.

Evidence: Dynamic-model regression verifies published and stored state remain unchanged after write failure.

### `3885744308`

Concern: Configured HTTP idle timeout is not applied to provider streams.

Outcome: Addressed by threading the setting into the dispatcher unless a request supplies a stricter explicit timeout.

Evidence: Dispatcher regression verifies configured and overridden timeouts.

### `3885744312`

Concern: RPC auto-compaction ignores enabled, reserve, and retained-tail settings.

Outcome: Addressed by initializing and using the complete compaction policy in threshold and preparation paths.

Evidence: RPC regression covers disabled mode and custom reserve and retained-token values.

### `3885744315`

Concern: `get_entries` ignores the accepted `since` cursor.

Outcome: Addressed by validating the entry cursor and returning only subsequent entries.

Evidence: RPC session regression covers valid, unknown, and terminal cursors.

### `3885744320`

Concern: `get_tree` aliases the flat entry list.

Outcome: Addressed by encoding the actual parent and children hierarchy from the session tree.

Evidence: RPC session regression verifies nested branch structure.

### `3885744326`

Concern: Codex WebSocket pooling is keyed by a constant account value.

Outcome: Addressed with a non-secret fingerprint of credential, account headers, endpoint, provider, and session.

Evidence: Codex pool regression verifies credential and endpoint changes create distinct connections.

### `3885744332`

Concern: RPC model changes are acknowledged without persistence.

Outcome: Addressed by appending the durable model-change entry before updating the agent.

Evidence: RPC regression verifies session restore uses the selected model.

### `3885744336`

Concern: Session lookup searches filenames instead of header IDs.

Outcome: Addressed by inspecting candidate session headers when filename matching does not resolve the request.

Evidence: Session argument regression resolves an explicit header ID whose filename is unrelated.
