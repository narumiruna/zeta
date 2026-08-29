# Pull request 1 review ledger

Target: [PR #1](https://github.com/narumiruna/zeta/pull/1), `narumi/feat/swift-native-pi-rewrite` into `main`.

Reviewed feedback is the Codex review submitted on 2026-08-28 and the three failing macOS CI checks for commit `9913698ceb5a5180e4bba57f7a5942fb6b3d38f2`.

Rounds six and seven continue in the [follow-up review ledger](2026-08-29_pr-1-review-ledger-followup.md).

## Inline feedback

### `3883403780`

Concern: Built-in tools publish empty argument schemas.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by strict published and runtime schemas for all seven built-in tools in `Sources/ZetaCLI/BuiltinToolSchemas.swift`.

Evidence: `testBuiltInToolSchemasAreStrictAndMatchRequiredArguments` verifies required fields, edit-array structure, types, and rejection of unknown fields.

### `3883403786`

Concern: Concurrent server runtime opens can create duplicate runtimes.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by tokenized in-flight open coalescing in `Sources/ZetaServer/PiServer.swift`.

Evidence: `testConcurrentAttachmentsShareOneRuntimeAndPreserveBothConnections` verifies one service open, two retained attachments, and correct disposal.

### `3883403794`

Concern: SSE decoding does not split CRLF-framed records.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by recognizing CRLF, LF, and CR record boundaries before normalizing field lines.

Evidence: `testSSEDecoderSplitsCRLFRecords` verifies separate CRLF events and Unicode line-separator preservation.

### `3883403801`

Concern: The migration default destination differs from the runtime default.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by deriving the destination from `ZetaPaths.agentDirectory` in `Sources/ZetaCLI/ManagementCommands.swift`.

Evidence: `testMigrationDefaultsToRuntimeAgentDirectory` verifies the default and explicit override.

### `3883403806`

Concern: SQLite FTS is rebuilt for every search.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by rebuilding only when the FTS table is first created and caching initialization per repository.

Evidence: `testSearchBuildsOnceAndTriggersMaintainTheIndexAcrossReopen` verifies trigger maintenance and reopen behavior without another rebuild.

### `3883403814`

Concern: OAuth provider extras do not round-trip through storage.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by encoding and decoding the `extras` field in `Sources/ZetaConfig/AuthStore.swift`.

Evidence: `testOAuthExtrasRoundTripThroughDisk` verifies detached disk persistence.

### `3883403817`

Concern: Exported transcript HTML permits unquoted event-handler injection.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by HTML-escaping the complete untrusted transcript and rendering it as preformatted text.

Evidence: `testStandaloneHTMLEscapesAllTranscriptMarkupIncludingUnquotedHandlers` covers unquoted handlers, SVG handlers, JavaScript URLs, and ordinary markup.

### `3883403825`

Concern: Installed package resources are not loaded at runtime.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by loading registry-selected global and trusted project package roots with containment and symlink validation.

Evidence: `testLoadsOnlyValidatedRegisteredGlobalAndTrustedProjectPackages` verifies loading, trust gating, and unsafe registry rejection.

### `3883403832`

Concern: Concurrent accepted RPC prompts can be dropped.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by atomically reserving the prompt task before returning acceptance and by draining a source-ordered queue.

Evidence: `testConcurrentRPCPromptsStartThenQueueWithoutDropping` verifies both accepted prompts appear in order.

### `3883403840`

Concern: `abort_bash` acknowledges without cancelling the process.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by retaining the active shell task and awaiting its process-group cancellation before acknowledgement.

Evidence: `testAbortBashWaitsForActiveCommandCancellation` verifies prompt cancellation, nonzero or cancelled original settlement, and no leaked test process.

### `3883403848`

Concern: `new_session` continues writing to the previous persistent file.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by creating, materializing, and swapping to a fresh `SessionManager` before accepting more events.

Evidence: `testNewSessionSwapsPersistentFile` verifies the new path exists and differs from the old path.

### `3883403854`

Concern: Bedrock bearer credentials are incorrectly signed with SigV4.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed with distinct bearer and SigV4 credential modes.

Evidence: `testBearerAndSigV4RequestsUseDistinctAuthorization` verifies bearer requests have no SigV4 headers and access-key requests remain signed.

### `3883403862`

Concern: Bedrock requests omit coding-tool definitions.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by Converse `toolConfig`, tool-use and tool-result payload conversion, and streamed tool-use reduction.

Evidence: `testResponsesAndBedrockPayloadsUseProviderSpecificContentAndTools` and `testToolUseStreamParsesFragmentedInputAndStopReason` cover the request and stream directions.

### `3883403873`

Concern: RPC auto-compaction has no effect during runs.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by checking before and after prompt execution and persisting successful compaction entries.

Evidence: `testRPCAutoCompactionRunsAfterThresholdCrossing` verifies a threshold crossing invokes summarization and replaces oversized history.

### `3883403880`

Concern: OpenAI tool-call deltas lose nested IDs, names, and indexes.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed with a nested tool-index to content-index reducer that accumulates each call independently.

Evidence: `testProviderEventReducerPreservesParallelOpenAIToolCalls` verifies out-of-order parallel deltas preserve IDs, names, and arguments.

### `3883403889`

Concern: Responses API messages use Chat Completions content block types.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed with Responses-specific `input_text` and `input_image` conversion plus native function-tool objects.

Evidence: `testResponsesAndBedrockPayloadsUseProviderSpecificContentAndTools` verifies the externally visible payload shape.

### `3883403895`

Concern: Anthropic thinking signatures and redacted payloads are discarded.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by retaining start metadata, signature deltas, and opaque redacted payloads in `ContentBlock.thinking`.

Evidence: `testProviderEventReducerPreservesAnthropicThinkingMetadata` verifies normal and redacted replay metadata.

### `3883403906`

Concern: Generated model compatibility metadata is discarded.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by retaining headers, compatibility metadata, thinking maps, and URL templates on `Model`.

Evidence: Payload construction now applies token-field, developer-role, strict-tool, reasoning-format, temperature, usage, and generated-header controls.

Evidence: `testBundledCatalogRetainsGeneratedRequestMetadata` and `testOpenAICompatAndThinkingMetadataAffectPayload` verify catalog and request behavior.

### `3883403916`

Concern: Google Vertex endpoint templates resolve to a sentinel host.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by retaining the template and resolving project, location, publisher, model, and SSE query fields at request time.

Evidence: `testVertexRequestResolvesTemplateAndGeneratedHeaders` verifies the complete endpoint and generated headers.

### `3883403926`

Concern: Non-tool plugin registrations are silently unavailable.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by transactionally rejecting unsupported non-tool registrations with an actionable diagnostic.

Evidence: `testPluginRuntimeRejectsUnsupportedRegistrationKinds` verifies no partial registration survives.

Evidence: `docs/user/plugins.md` and the all-capabilities example now state the host boundary explicitly.

### `3883403933`

Concern: The editor retains submitted text.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by clearing state after capturing the submitted value.

Evidence: `testEditorClearsFullValueAfterSubmit` verifies callback content and empty post-submit state.

### `3883403942`

Concern: Large bracketed-paste contents are discarded.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by retaining the complete pasted value rather than replacing it with an unexpandable marker.

Evidence: `testEditorClearsFullValueAfterSubmit` submits and verifies a paste longer than ten lines.

### `3883403953`

Concern: Live requests do not apply cross-provider message transforms.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by applying `MessageTransforms.forModel` immediately before every provider stream call with the current model.

Evidence: `testProviderMessageTransformUsesModelChangedAfterAgentCreation` verifies a post-construction model change transforms the next request.

## Second-round inline feedback

### `3885424957`

Concern: RPC model changes retain the startup provider and credential transport.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by model-keyed per-request transport and credential dispatch in `Sources/ZetaCLI/ProviderStream.swift`.

Evidence: `testModelDispatcherUsesEachRequestModelAndTransport` verifies HTTP, Codex, and Bedrock selection after model changes.

### `3885424963`

Concern: Rejected switch, fork, and clone operations can mutate persistence before the agent rejects them.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by reserving a session-mutation gate and checking agent idleness before manager mutation.

Evidence: `testSessionMutationsRejectBeforeChangingManagerWhileBusy` verifies the persistent file and messages remain unchanged.

### `3885424969`

Concern: Interactive `/new` does not rotate the persistent session.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by creating and selecting a new persistent session after the old run settles.

Evidence: `testInteractiveNewSessionRotatesPersistentFile` verifies distinct durable paths.

### `3885424976`

Concern: Vertex ADC bearer credentials are not connected to request authorization.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by resolving Vertex API-key and bearer modes for each request and applying their distinct headers.

Evidence: Vertex regressions verify API keys, pre-issued ADC tokens, authorized-user refresh exchange, and bearer request headers.

### `3885424977`

Concern: RPC decoding accepts fields outside each command schema.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by strict command-specific `JSONSchema` validation with forbidden additional properties.

Evidence: `testStrictRPCRejectsCommandSpecificUnknownAndInvalidFields` covers misspellings, unknown fields, invalid enums, and missing required fields.

### `3885424979`

Concern: Gemini streamed function-call parts are ignored.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by iterating every candidate part and reducing text, thinking, and function calls independently.

Evidence: `testProviderEventReducerDecodesEveryGeminiPart` verifies parallel calls, arguments, signatures, usage, and stop reasons.

### `3885424982`

Concern: Concurrent client lease acquisition can suspend before reserving ownership.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by reserving ownership first and coalescing in-flight attachment operations.

Evidence: The concurrent shared and mixed exclusive/shared lease regressions verify one attach and stable ownership.

### `3885424989`

Concern: Unix transport writes can terminate the process with `SIGPIPE`.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by setting `SO_NOSIGPIPE` on created, probed, listening, and accepted sockets.

Evidence: `testWriteAfterPeerDisconnectReturnsErrorWithoutSIGPIPE` verifies process survival and a surfaced transport error.

### `3885424992`

Concern: Coding-agent sessions should reject every malformed complete JSONL record.

Initial outcome: Incorrect and conflicting with the pinned compatibility contract.

Final outcome: No behavior change was made because coding-agent version 3 deliberately skips malformed records.

Evidence: Pinned `packages/coding-agent/src/core/session-manager.ts` lines 303 through 310 and 503 through 509 explicitly skip malformed lines.

Evidence: Pinned `packages/coding-agent/test/session-manager/file-operations.test.ts` verifies malformed-only, mixed valid and malformed, and malformed-tail behavior.

### `3885424995`

Concern: Any terminating tool result should stop a mixed parallel batch.

Initial outcome: Incorrect and conflicting with the pinned compatibility contract.

Final outcome: No behavior change was made because the pinned agent stops only when every finalized result terminates.

Evidence: Pinned `packages/agent/src/agent-loop.ts` lines 580 through 581 use `every`, and `agent-loop.test.ts` verifies mixed batches continue.

### `3885425000`

Concern: Startup ignores configured steering and follow-up modes.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by applying both settings while configuring the agent.

Evidence: `testStartupSettingsConfigureAgentQueueModes` verifies both modes become `all`.

### `3885425004`

Concern: Usage records do not update SQLite session aggregates.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by parsing and applying cached, uncached, total-token, and cost deltas in the record transaction.

Evidence: SQLite usage regressions verify aggregates and rollback of records, sequence allocation, and statistics on malformed or missing state.

### `3885425006`

Concern: Existing coding-agent sessions rewrite all JSONL for each assistant entry.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by normal append after materialization while preserving first-assistant delayed creation and migration rewrites.

Evidence: `testLoadedSessionAppendsAssistantWithoutRewritingExistingJSONL` verifies prior bytes remain unchanged and malformed compatibility records are preserved.

### `3885425012`

Concern: Server mutations do not publish snapshots to other attached clients.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by broadcasting authoritative `session_snapshot` events after every runtime mutation.

Evidence: Server regressions verify all attached clients receive snapshots and one failed send does not fail the mutation or other clients.

### `3885425013`

Concern: Agent abort does not cancel independent provider producers.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by stream termination plumbing, producer-task attachment, and explicit provider cancellation.

Evidence: `testAbortCancelsProviderProducerAndDoesNotWaitForResult` verifies prompt settlement and producer cancellation without a terminal provider event.

### `3885425016`

Concern: Harness `findEntries(afterSequence:)` uses the reverse comparison.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by the forward exclusive `sequence > afterSequence` predicate.

Evidence: `testFindEntriesAfterSequenceUsesForwardExclusiveBound` verifies incremental retrieval.

### `3885425018`

Concern: Compaction sums cumulative request usage for each assistant message.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by estimating assistant output or content rather than cumulative input history.

Evidence: `testAssistantEstimatesDoNotSumCumulativeRequestUsage` verifies linear per-message estimates.

### `3885425021`

Concern: Thinking-level changes are not persisted.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by appending thinking-level session entries before RPC and interactive acknowledgement.

Evidence: `testThinkingCommandsPersistToSessionTranscript` verifies restore behavior.

### `3885425025`

Concern: Non-finite temperatures trap through forced `JSONNumber` creation.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by validating finiteness and propagating throwing number conversion in every provider payload branch.

Evidence: `testProviderPayloadsRejectNonFiniteTemperatures` covers NaN and both infinities across provider families.

### `3885425029`

Concern: Auth check reports invalid OAuth credentials as ready.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by sharing runtime credential resolution and checking expiry and nonempty content.

Evidence: Auth and CLI readiness regressions cover expired OAuth, blank values, environment fallback, and valid OAuth.

## Third-round inline feedback

### `3885469697`

Concern: Server readiness is published after sending the hello.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by marking the tokenized connection ready before hello publication, queueing same-batch requests, and closing on send failure.

Evidence: Server handshake regressions verify immediate post-hello requests and failed hello sends.

### `3885469702`

Concern: Gemini usage metadata is not decoded.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by decoding Google prompt, candidate, thought, cached, and total token counts.

Evidence: Provider regressions verify Gemini token accounting and cache separation.

### `3885469706`

Concern: Provider usage does not apply selected model pricing.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by retaining the selected model in the reducer and calculating input, output, cache-read, and cache-write costs from generated rates.

Evidence: Provider regressions verify nonzero cost components and totals from known model rates.

### `3885469712`

Concern: Concurrent client connection callers do not await the active connection attempt.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by tokenized connection-operation coalescing with shared success and failure settlement.

Evidence: Client regressions cover concurrent success, shared failure, and a clean retry.

### `3885469719`

Concern: Failed session persistence leaves unpersisted entries in memory.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by completing or rolling back durable writes before mutating entries, indexes, leaves, or materialization state.

Evidence: Session regressions cover existing-file append failure and delayed first-assistant materialization failure.

### `3885469722`

Concern: Delayed Escape decoding races new terminal input.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by confining decoder mutation, timeout scheduling, cancellation, and reset to one serial input pipeline.

Evidence: Terminal regressions exercise Escape cancellation and new input near the timeout boundary.

### `3885469725`

Concern: OpenAI text and thinking block lifecycles omit end events.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by tracking open content blocks and finalizing them exactly once on Chat Completions and Responses terminal events.

Evidence: Provider lifecycle regressions verify balanced and nonduplicated text and thinking events.

### `3885469733`

Concern: Bedrock signing can use a region that differs from the selected endpoint.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by deriving the endpoint region and rejecting conflicting AWS region variables before constructing the provider.

Evidence: CLI region regressions cover derived, matching, and mismatched configurations.

### `3885469740`

Concern: Empty credential environment variables mask later valid fallbacks.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by trimming and skipping empty values throughout stored and environment credential resolution.

Evidence: AuthStore regressions verify an empty first Anthropic variable falls through to a valid API key.

### `3885469741`

Concern: Unknown long CLI flags are accepted and discarded.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by rejecting unsupported long flags while preserving the `--` message terminator.

Evidence: CLI argument regressions cover typographical flags and post-terminator messages.

### `3885469744`

Concern: HTTP stream failures discard partial assistant output.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by terminating an already-started stream with the accumulated reducer partial plus error metadata.

Evidence: Provider regression coverage verifies partial text survives a post-start transport failure.

### `3885469747`

Concern: `integer(javascriptSafe: false)` still requires JavaScript-safe values.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by exact preserved-spelling integer parsing and signed 64-bit range checks without `Double` conversion.

Evidence: Validation regressions cover Int64 boundaries, exponent spellings, fractions, and overflow while retaining JavaScript-safe behavior.

### `3885469750`

Concern: Package subprocesses block actor isolation.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by a cancellable nonisolated async subprocess helper with process-group termination.

Evidence: Package regressions verify actor responsiveness, cancellation, staging cleanup, and publication rollback.

### `3885469752`

Concern: Ctrl-C cannot interrupt an active initial interactive prompt.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by aborting and draining the active agent run when exit is requested.

Evidence: Interactive CLI regressions verify prompt cancellation and terminal settlement.

## Fourth-round inline feedback

### `3885588589`

Concern: Package replacement deletes the previous backup before the registry index is durable.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by retaining the backup through successful index persistence and restoring it on failure.

Evidence: Package rollback regressions inject index write failures for install, remove, and update.

### `3885588590`

Concern: TUI input mutation races component rendering.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by serializing input handling, component state, rendering, and terminal writes on reentrancy-aware executors.

Evidence: TUI stress coverage passes under ThreadSanitizer.

### `3885588592`

Concern: OAuth callback continuation installation races a completed callback.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by consuming a pending result or installing the continuation in one locked transition.

Evidence: OAuth regressions exercise both callback-before-waiter and waiter-before-callback orders.

### `3885588593`

Concern: Credential helper output can deadlock a full pipe before process exit.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by draining helper output asynchronously while the process runs and retaining cancellation handling.

Evidence: AuthStore regression coverage resolves a helper output larger than the pipe buffer.

### `3885588594`

Concern: A plugin timeout leaves a late response queued for the next request.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by invalidating and stopping the plugin host on read timeout or failure before releasing queued requests.

Evidence: Plugin host regressions verify a late response cannot contaminate a subsequent call.

### `3885588596`

Concern: OpenAI Responses function-call metadata is lost before argument deltas.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by seeding call ID, name, namespace, and output-index mapping from `response.output_item.added`.

Evidence: Provider regressions verify interleaved parallel calls and balanced tool events.

### `3885588597`

Concern: RPC image attachments are accepted but discarded.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by strict canonical base64 and MIME validation followed by `ContentBlock.image` construction for prompt, steer, and follow-up.

Evidence: RPC image regressions cover valid and invalid attachments for all three commands.

### `3885588598`

Concern: Repeated compactions map projected indexes into the raw branch incorrectly.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by resolving retained entries against the same projected context sequence used by the agent.

Evidence: A two-compaction reload regression verifies summarized history is not resurrected.

### `3885588599`

Concern: RPC compaction ignores custom instructions.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by forwarding `customInstructions` to the summary prompt builder.

Evidence: RPC compaction regression verifies the custom text reaches the provider prompt.

### `3885588600`

Concern: Empty telemetry arrays lose their scalar variant during Codable round trips.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed with tagged encoding for empty string, number, and boolean arrays while retaining legacy nonempty encoding.

Evidence: Telemetry schema regressions verify all empty variants round-trip exactly.

### `3885588601`

Concern: Package removal trusts unsafe registry directory paths.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by validating a single contained path component before any filesystem mutation.

Evidence: Package regressions cover traversal, absolute, separator, and external-target variants.

### `3885588602`

Concern: File editing silently replaces invalid UTF-8 bytes.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by requiring lossless UTF-8 decoding before text replacement.

Evidence: File-tool regression verifies rejection leaves every original byte unchanged.

### `3885588604`

Concern: Cancelled client requests remain pending until server response or disconnect.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by atomically removing and cancelling the pending continuation with double-settlement protection.

Evidence: Client regressions cover cancellation racing response and disconnect.

### `3885588605`

Concern: HTML export embeds bare messages instead of coding-agent JSONL.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by exporting a version 3 header and `SessionEntry` records from persistent state or a valid synthesized in-memory session.

Evidence: Export regressions reopen the downloaded JSONL through session format detection and `SessionManager`.

## Fifth-round inline feedback

### `3885635397`

Concern: Plugin tool schemas are discarded.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by strict plugin JSON Schema decoding for both published definitions and runtime argument validation.

Evidence: Plugin regressions verify required arguments, coercion, rejection, and transactional failure for unsupported schemas.

### `3885635400`

Concern: Large SQLite forks execute synchronously on the cooperative actor executor.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by assigning the repository a dedicated serial storage executor that preserves one-at-a-time SQLite access outside the cooperative pool.

Evidence: SQLite fork and responsiveness regressions pass with serialized transactions.

### `3885635402`

Concern: Normalized package directory names can collide across identifiers.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by collision-resistant identifier hashes, legacy path reuse, and duplicate-owner validation.

Evidence: Package regressions verify colliding identifiers install and remove independently and malformed duplicate registries are rejected.

### `3885635405`

Concern: Cancelling a stream after deltas loses accumulated output.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by retaining the latest partial in `AssistantEventStream` and using it for the single aborted terminal event.

Evidence: Provider cancellation regressions verify streamed text remains in the aborted assistant.

### `3885635406`

Concern: Codex WebSocket failures discard partial output.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by tracking start state and terminating with the reducer partial on post-start failure.

Evidence: Codex regressions cover malformed and closed streams after text deltas.

### `3885635408`

Concern: The configured retry-delay ceiling is ignored.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by threading the setting into retry configuration and overflow-safe exponential clamping.

Evidence: Agent and CLI regressions verify the maximum delay while preserving the existing configuration API.

### `3885635411`

Concern: Bedrock model IDs are URL-encoded twice.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by path-segment construction that encodes the raw model ID exactly once.

Evidence: Bedrock request regressions cover colon-bearing catalog IDs.

### `3885635413`

Concern: Failed server creates publish unreachable runtime ownership.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by validating identity and obtaining the initial snapshot before publishing runtime or attachment state, with disposal on every failure.

Evidence: Server regressions cover snapshot failure, identity mismatch, connection races, and rollback.

### `3885635415`

Concern: Dash-prefixed grep patterns are parsed as options.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by passing patterns through ripgrep's `--regexp` option.

Evidence: Search-tool regressions find `--help`-style text through external and fallback paths.

### `3885635416`

Concern: Incomplete SSE records can grow without bound.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by a 16 MiB pending-record limit and linear boundary scanning.

Evidence: SSE regressions verify oversize rejection before a delimiter and normal fragmented decoding.

### `3885635418`

Concern: Image generation ignores request timeout options.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by converting the requested duration to `URLRequest.timeoutInterval`.

Evidence: Image-provider request regression verifies the configured interval.

### `3885635420`

Concern: Client convenience methods discard structured server failures.

Initial outcome: Actionable and not yet addressed.

Final outcome: Addressed by central failure-envelope mapping to `PiClientError.server` across list, create, attach, detach, and session commands.

Evidence: Client regressions verify error code, message, and details are preserved.

## Check feedback

### Repository gates

Initial outcome: Actionable and not yet addressed because the runner has no `uv`.

Final outcome: Addressed by installing pinned uv `0.9.26` with architecture-specific checksums before the gate.

Final outcome: Search tests no longer require a preinstalled `rg`, and SQLite search falls back to the built-in Unicode tokenizer when the host lacks trigram support.

Local evidence: Workflow YAML, embedded shell syntax, repository scripts, and the complete repository gate were validated before push.

### Swift arm64

Initial outcome: Actionable and not yet addressed because the runner provides Swift 6.1 while the package requires Swift 6.2.

Final outcome: Addressed by installing pinned Swift `6.2.0` and asserting the active version before building.

Local evidence: The strict arm64 build and complete 171-test suite passed before push.

### Swift x86_64

Initial outcome: Actionable and not yet addressed because the runner provides Swift 6.1 while the package requires Swift 6.2.

Final outcome: Addressed by installing pinned Swift `6.2.0` on the Intel runner and asserting both version and architecture.

Local evidence: The workflow uses the same strict build and test commands as the verified local gate, while hosted Intel execution is verified by the post-push check.
