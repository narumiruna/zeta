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

## Eighth-round inline feedback

### `3885789699`

Concern: CBOR map duplicate checks are quadratic.

Outcome: Addressed by tracking decoded map keys in a `Set` while preserving ordered values.

Evidence: CBOR stress coverage decodes a 50,000-entry map and retains duplicate rejection.

### `3885789703`

Concern: Grep output is bounded only after full process capture.

Outcome: Addressed by terminating capture at match and byte limits during asynchronous draining.

Evidence: Search regressions verify bounded output and child-process cleanup.

### `3885789705`

Concern: Dash-prefixed find patterns are parsed as options.

Outcome: Addressed by placing the pattern and path after fd's `--` delimiter.

Evidence: Search regressions verify literal dash-prefixed patterns.

### `3885789707`

Concern: Failed auth persistence publishes rejected in-memory credentials.

Outcome: Addressed by persisting a candidate credential dictionary before assigning actor state.

Evidence: AuthStore failure injection verifies set and delete leave memory and disk bytes unchanged.

### `3885789709`

Concern: File edits normalize unaffected mixed line endings.

Outcome: Addressed by matching normalized text while applying replacements against original byte ranges and separators.

Evidence: Byte-exact mixed CRLF and LF regressions preserve BOM and untouched separators.

### `3885789712`

Concern: Codex waits forever on incomplete and failed terminal responses.

Outcome: Addressed by mapping incomplete output limits to `length`, failed responses to errors, and ending receive immediately.

Evidence: Codex regressions verify partial output, stop reasons, and receive counts.

### `3885789714`

Concern: SSH URL userinfo is mistaken for a Git reference suffix.

Outcome: Addressed by parsing references only after the repository path and preserving SSH and SCP userinfo.

Evidence: Package-source regressions cover SSH URLs, SCP forms, and explicit references.

### `3885789715`

Concern: Combining-scalar insertion leaves the editor cursor outside valid grapheme boundaries.

Outcome: Addressed by recomputing cursor position from the post-edit grapheme sequence for insertion, paste, completion, delete, and backspace.

Evidence: TUI regressions cover combining marks and ZWJ emoji edits without traps.

### `3885789716`

Concern: CRLF resource frontmatter is not parsed.

Outcome: Addressed by line-ending-aware delimiter parsing that preserves body line endings.

Evidence: Resource regressions load CRLF prompts and skills while retaining LF behavior.

## Ninth-round inline feedback

### `3885834491`

Concern: Slow runtime open can attach a disconnected client and leak ownership.

Outcome: Addressed by revalidating the tokenized ready client before publication and disposing an otherwise unowned runtime.

Evidence: Server race regression disconnects during open and verifies no stale connection or runtime remains.

### `3885834492`

Concern: Cancelling one shared connect waiter aborts every waiter.

Outcome: Addressed with individual waiter accounting that cancels the shared attempt only after the final waiter cancels.

Evidence: Client regression cancels one concurrent waiter while the other connects successfully.

### `3885834494`

Concern: Deferred session persistence errors are never surfaced.

Outcome: Addressed by draining persistence failures at CLI, RPC, and mode settlement boundaries before reporting success.

Evidence: Injected session-write failures produce explicit failed outcomes.

### `3885834496`

Concern: NPM package archives are fully buffered without a compressed-size bound.

Outcome: Addressed by streaming tarballs to a temporary file with a 100 MiB compressed limit and cancellation cleanup.

Evidence: Package regressions cover oversize, HTTP failure, cancellation, and staging cleanup.

### `3885834497`

Concern: Package commands ignore the required `--local` flag.

Outcome: Addressed by accepting `--local` and `-l` in either flag position and enforcing project trust and root selection.

Evidence: Management-command regressions verify local and global destinations.

### `3885834499`

Concern: Requests queued during handshake are unbounded.

Outcome: Addressed with count and encoded-byte budgets that close an exceeding peer.

Evidence: Server regressions exercise both limits and ordinary same-batch requests.

### `3885834502`

Concern: Plugin hosts can publish duplicate or built-in tool names.

Outcome: Addressed by validating cross-host and built-in collisions before any host or binding is published.

Evidence: Plugin runtime regressions verify transactional rejection.

## Tenth-round inline feedback

### `3885868033`

Concern: Undecodable v1 and v2 records should reject migration.

Outcome: The requested rejection conflicts with pinned malformed-line skipping, so malformed JSON remains skipped.

Outcome: Zeta now preserves every parseable unknown or malformed typed object during migration and later materialization instead of deleting it.

Evidence: Pinned session-manager source and tests require malformed JSON skipping, while the new regression verifies unknown raw records survive migration.

### `3885868034`

Concern: `cycle_model` is not persisted.

Outcome: Addressed by recording the selected model before updating and acknowledging the agent.

Evidence: RPC restore regression covers cycled models.

### `3885868036`

Concern: Session names can be acknowledged before materialization.

Outcome: Addressed by materializing the name entry before successful return.

Evidence: New-session naming regression reloads the durable name.

### `3885868038`

Concern: RPC retry state ignores configured retry settings.

Outcome: Addressed by initializing and toggling from the loaded retry count, base delay, and maximum delay policy.

Evidence: RPC state and toggle regressions verify configured values are retained.

### `3885868040`

Concern: Assistant events use an unbounded progress buffer with cumulative snapshots.

Outcome: Addressed with bounded newest-progress buffering while terminal state and `result()` remain separately reliable.

Evidence: Stream stress regression verifies bounded delivery and terminal settlement.

### `3885868041`

Concern: Bedrock event frames trust arbitrary declared lengths.

Outcome: Addressed by rejecting total lengths above a configurable default limit as soon as the prelude arrives.

Evidence: Bedrock decoder regressions reject oversized preludes without buffering payload bytes.

### `3885868044`

Concern: One invalid OAuth callback terminates the listener.

Outcome: Addressed by returning a 400 for that connection while continuing to await the expected state.

Evidence: OAuth regression sends an invalid callback followed by a valid callback.

### `3885868046`

Concern: Unknown response IDs are silently discarded by the client.

Outcome: Addressed by treating unsolicited or duplicate response IDs as fatal protocol errors that settle pending work.

Evidence: Client regressions cover unknown and duplicate IDs.

### `3885868048`

Concern: Failed compaction persistence leaves live and durable state divergent.

Outcome: Addressed by restoring the original agent messages when persistence fails in manual or automatic compaction.

Evidence: Injected-failure regressions verify exact message restoration.

### `3885868052`

Concern: Project settings overrides leak into global writes.

Outcome: Addressed by retaining separate global and project representations and persisting only the modified global candidate.

Evidence: Settings regression modifies an unrelated field and verifies project-only values remain absent globally.

### `3885868054`

Concern: RPC `parentSession` is ignored for new sessions.

Outcome: Addressed by carrying the supplied parent into the durable replacement header.

Evidence: New-session regression reloads the parent relationship.

### `3885868057`

Concern: RPC `export_html` ignores `outputPath`.

Outcome: Addressed by atomically writing the HTML to the requested path and returning it, while omitted paths retain inline output.

Evidence: Export regressions cover file and inline modes.

### `3885868059`

Concern: Interactive assistant failures render as blank output.

Outcome: Addressed by rendering `errorMessage` for error or aborted assistants without text content.

Evidence: Interactive transcript regression verifies the visible diagnostic.

## Eleventh-round inline feedback

### `3885890797`

Concern: File reads allocate complete large files before applying limits.

Outcome: Addressed by incremental text reading with 2,000-line and 50 KiB limits before buffering the result.

Evidence: Sparse-file regression verifies bounded memory-facing output and offset behavior.

### `3885890802`

Concern: Package archives accept FIFOs and other special files.

Outcome: Addressed by allowing only regular files and directories in archive listings and validated package trees.

Evidence: FIFO, device-shaped archive, and package-tree regressions reject publication and avoid blocking.

### `3885890804`

Concern: Server connection queued writes have no pending-byte budget.

Outcome: Addressed with atomic pending-byte reservation, exact release, limit rejection, and connection closure while preserving the public initializer.

Evidence: Concurrent slow-peer regressions verify bounded admission and settlement.

### `3885890807`

Concern: Stream protocol errors do not settle `result()` waiters.

Outcome: Addressed by synthesizing a terminal error assistant, resuming every waiter, and terminating iterator delivery consistently.

Evidence: Stream regression races invalid terminal events with result waiters.

### `3885890811`

Concern: Prompts queued behind an RPC run are unbounded.

Outcome: Addressed with 64-prompt and 16 MiB encoded-content budgets that are released on dequeue or clear.

Evidence: RPC queue regressions verify rejection, byte accounting, and `clear_queue` recovery.

### `3885890812`

Concern: SigV4 canonical paths decode encoded separators.

Outcome: Addressed by canonicalizing `percentEncodedPath` so `%2F` remains within the model path segment and is encoded exactly once.

Evidence: Deterministic SigV4 regression covers a slash-bearing Bedrock model identifier.

### `3885890813`

Concern: Interactive `/new` clears live history before replacement materialization succeeds.

Outcome: Addressed with two-phase replacement that materializes first, resets the agent second, and publishes the controller last.

Evidence: Interactive and RPC failure regressions verify old messages and session ownership remain unchanged.

## Twelfth-round inline feedback

### `3885929304`

Concern: Fragmented OAuth redirects are parsed before the request line is complete.

Outcome: Addressed by buffering through LF or CRLF under the existing 16 KiB request limit.

Evidence: OAuth regressions fragment valid and oversized request lines.

### `3885929306`

Concern: Cancelled attachment waiters leak reserved client leases.

Outcome: Addressed with per-lease waiters that remove only the cancelled reservation and detach orphaned completed attachments.

Evidence: Client regressions cancel one shared attachment waiter while preserving another.

### `3885929308`

Concern: Compressed package limits do not bound expanded archive size.

Outcome: Addressed by validating member count, per-file size, and total expanded bytes before extraction.

Evidence: Tar metadata regressions reject compressed bombs and accept bounded archives.

### `3885929311`

Concern: Failed initial attach snapshots leave unreachable server ownership.

Outcome: Addressed by obtaining and validating the snapshot before publishing both attachment sets.

Evidence: Server regression injects snapshot failure and verifies disposal and clean ownership.

### `3885929314`

Concern: Cancelled queued plugin requests later acquire the slot and kill the host.

Outcome: Addressed with cancellable waiter removal before slot acquisition.

Evidence: Plugin regression cancels a queued request while later calls continue on the same host.

### `3885929318`

Concern: Atomic file writes and edits lose existing POSIX permissions.

Outcome: Addressed by capturing and restoring existing file modes across replacements while new files retain safe defaults.

Evidence: File-tool regressions preserve `0755` and `0600` modes byte-for-byte.

### `3885929322`

Concern: RPC does not restore durable session names.

Outcome: Addressed by deriving the latest name or tombstone on startup and switch.

Evidence: Stats and export-title regressions reflect restored names.

### `3885929325`

Concern: JSON mode exits zero for terminal assistant errors.

Outcome: Addressed by inspecting final assistant state after emitting all events and returning nonzero for error or aborted results.

Evidence: JSON-mode regressions cover single and multiple prompts.

### `3885929327`

Concern: Session format detection truncates long headers at 4,096 bytes.

Outcome: Addressed by incrementally reading the first record up to the 16 MiB JSON limit.

Evidence: Format regressions detect long valid headers and reject oversized unterminated headers.

### `3885929330`

Concern: Negative or overflowing snippet lengths can trap search.

Outcome: Addressed by validating nonnegative lengths and using overflow-safe Unicode bounds.

Evidence: Search regressions cover negative, `Int.max`, and grapheme-rich snippets.

### `3885929331`

Concern: Project trust treats `ask` exactly like `never`.

Outcome: Addressed with interactive trust selection and durable decisions while noninteractive mode safely denies with guidance.

Evidence: Trust regressions preserve approval overrides and distinguish ask and never.

## Ninth-round inline feedback

### `3885868033`

Concern: Undecodable v1 and v2 session records are omitted before the migration rewrite.

Outcome: The requested rejection conflicts with the pinned contract, so malformed JSON remains intentionally skipped instead of rejecting the session.

Outcome: The related parseable-record loss was addressed by rewriting every migrated JSON object, including unknown future entry types and malformed typed entries, rather than only successfully typed entries.

Pinned source evidence: At commit `56700d42ed65a94a80af7376adb19a9298065164`, `packages/coding-agent/src/core/session-manager.ts` lines 503 through 509 explicitly skip malformed JSON, lines 899 and 918 through 920 pass those filtered records into migration and rewrite, and lines 980 through 986 rewrite that filtered set.

Pinned source evidence: The same file's lines 235 through 255 migrate every parseable non-header object without discriminated type validation, and lines 984 through 986 preserve all such objects during rewrite.

Pinned test evidence: `packages/coding-agent/test/session-manager/file-operations.test.ts` lines 52 through 55 and 71 through 80 verify malformed-only input is rejected as a session while malformed records mixed into a session are skipped.

Zeta evidence: `testV1MigrationSkipsMalformedJSONAndPreservesUndecodableObjects` verifies malformed JSON is skipped while parseable unknown and malformed typed objects survive migration and later materialization.

## Thirteenth-round inline feedback

### `3885964578`

Concern: Failed or aborted provider responses can retain and execute completed tool calls.

Outcome: Actionable and addressed by generating non-executed error results for every non-successful terminal reason, excluding those synthetic results from retry context, and continuing tool turns only after successful responses.

Evidence: Agent regressions cover failed and aborted retained calls, zero tool executions, safe retry context, and no unintended continuation.

### `3885964579`

Concern: Image reads buffer unbounded files before base64 encoding.

Outcome: Actionable and addressed with a 20 MiB limit checked from file metadata and while incrementally reading both tool and CLI image attachments.

Evidence: A sparse oversized-image regression rejects the file before buffering it.

### `3885964581`

Concern: The no-`rg` grep fallback loads each candidate file completely.

Outcome: Actionable and addressed with incremental 16 KiB reads, bounded line and output state, strict streaming UTF-8 validation, and cooperative cancellation.

Evidence: Search regressions cover oversized lines, chunk-boundary Unicode, output limits, malformed UTF-8, and cancellation.

### `3885964583`

Concern: Anthropic OAuth credentials are emitted as `x-api-key` rather than bearer authorization.

Outcome: Actionable and addressed by preserving API-key versus bearer credential kinds from storage and environment resolution through HTTP request construction.

Evidence: AI and CLI regressions verify stored OAuth and `ANTHROPIC_OAUTH_TOKEN` produce `Authorization: Bearer`, while API keys continue to produce `x-api-key`.

### `3885964586`

Concern: A valid lease for one session can mutate another session.

Outcome: Actionable and addressed by validating the lease session before every lease-protected entry, record, lane, name, label, and fact mutation.

Evidence: SQLite regressions attempt every protected mutation with a different session's lease and verify stale-lease failures with no writes.

### `3885964588`

Concern: Malformed or non-object Bedrock event payloads are silently skipped.

Outcome: Actionable and addressed by rejecting both cases as invalid provider responses while preserving accumulated stream partials.

Evidence: Bedrock regressions cover malformed JSON after content and standalone non-object JSON.

### `3885964591`

Concern: A failed trust-store write still publishes the candidate in memory.

Outcome: Actionable and addressed by persisting a candidate dictionary before replacing actor state.

Evidence: A configuration regression injects a persistence failure and verifies the rejected decision remains absent from memory and later disk writes.

### `3885964592`

Concern: The migration command defaults source and destination to the same directory.

Outcome: Actionable and addressed by requiring an explicit destination and rejecting equivalent source and destination paths.

Evidence: CLI and migration regressions verify the missing-destination error, default Pi source, explicit destination, same-path rejection, and unchanged source data.

## Thirteenth-round verification

The focused strict-concurrency suite passed 170 tests with no failures.
The complete repository gate passed 304 XCTest cases and 56 Swift Testing cases against the clean pinned oracle.
The complete Address Sanitizer and Thread Sanitizer suites each passed the same 360 tests without findings.
API compatibility and generated symbol documentation checks passed with 2,021 public symbols across 30 modules.

## Fourteenth-round inline feedback

### `3886063939`

Concern: A clean SSE EOF without a provider terminal event is treated as a successful assistant response.

Outcome: Actionable and addressed by rejecting EOF while the reducer remains pending instead of inferring stop or tool-use success.

Evidence: An HTTP regression ends a successful SSE body after partial text and verifies an error terminal preserving that partial.

### `3886063941`

Concern: Edit buffers arbitrarily large files and creates multiple full-size copies.

Outcome: Actionable and addressed with a 20 MiB metadata and incremental-read limit before edit decoding or normalization.

Evidence: A sparse oversized-edit regression fails before buffering and preserves the original file size.

### `3886063942`

Concern: Session ID resolution loads every complete transcript just to inspect its header.

Outcome: Actionable and addressed by incrementally reading bounded JSONL records and returning immediately when the session header is found.

Evidence: Session resolution scans past a 512 MiB sparse transcript without loading its body and selects the requested header ID.

### `3886063943`

Concern: A cleanup-oriented detach failure leaves an orphaned server attachment with no retry.

Outcome: Actionable and addressed by scheduling orphan detachment after removing the inactive lease following a dispose failure.

Evidence: A client regression injects one detach failure and verifies the automatic second detach succeeds before reacquisition.

### `3886063945`

Concern: An unknown explicit provider silently falls back to the first model.

Outcome: Actionable and addressed by returning an unknown-model error when no model belongs to the requested provider.

Evidence: A CLI regression verifies a misspelled provider cannot select an unrelated model.

### `3886063950`

Concern: Interactive exit, abort, and new-session operations do not cancel active direct shell commands.

Outcome: Actionable and addressed by tracking the direct-shell task and cancelling and awaiting it at each lifecycle boundary.

Evidence: An interactive regression launches a long-running shell process, requests exit, and verifies the process is gone before exit completes.

### `3886063953`

Concern: Parsed JSON object duplicate detection performs a linear key lookup for every insertion.

Outcome: Actionable and addressed by tracking parser keys in a set while accumulating ordered entries.

Evidence: A 50,000-key ordered-object regression decodes successfully while duplicate-key rejection remains covered.

### `3886063959`

Concern: Interactive startup ignores the configured fullscreen TUI mode.

Outcome: Actionable and addressed by selecting `AltScreenTUI` for fullscreen settings and honoring the transcript-on-exit setting.

Evidence: A CLI regression verifies fullscreen settings construct the alternate-screen renderer.

### `3886063965`

Concern: Malformed non-header session records should reject migration instead of being skipped.

Outcome: Incorrect for the pinned coding-agent v3 contract, so malformed JSON remains intentionally skipped.

Pinned source evidence: At `56700d42ed65a94a80af7376adb19a9298065164`, `packages/coding-agent/src/core/session-manager.ts` lines 503 through 509 explicitly skip malformed JSON, and lines 918 through 920 and 980 through 986 migrate and rewrite the filtered records.

Pinned test evidence: `packages/coding-agent/test/session-manager/file-operations.test.ts` lines 52 through 55, 71 through 81, and 94 through 102 require malformed records and malformed tails to be skipped while valid records remain.

Related protection: Zeta preserves every parseable unknown object during migration, as verified by `testV1MigrationSkipsMalformedJSONAndPreservesUndecodableObjects`.

### `3886063969`

Concern: Concurrent package managers can overwrite each other's stale registry snapshots.

Outcome: Actionable and addressed with a cross-process registry lock and an authoritative index reload inside every install, remove, and update publication transaction.

Evidence: A stale-manager regression installs two packages and removes one through independently initialized managers without losing or resurrecting entries.

## Fourteenth-round verification

The complete local repository gate passed 311 XCTest cases and 57 Swift Testing cases against the clean pinned oracle.
The complete local Address Sanitizer and Thread Sanitizer suites each passed the same 368 tests without findings.
Strict concurrency, warnings-as-errors, formatting, file-length, API compatibility, generated documentation, and interoperability checks passed.
GitHub CI was not used as completion evidence for this round, per maintainer direction.
