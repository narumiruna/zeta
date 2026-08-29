# Pull request 1 review ledger

Target: [PR #1](https://github.com/narumiruna/zeta/pull/1), `narumi/feat/swift-native-pi-rewrite` into `main`.

Reviewed feedback is the Codex review submitted on 2026-08-28 and the three failing macOS CI checks for commit `9913698ceb5a5180e4bba57f7a5942fb6b3d38f2`.

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

Evidence: `testAbortBashWaitsForActiveCommandCancellation` verifies prompt cancellation, a failed original request, and no leaked test process.

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

## Check feedback

### Repository gates

Initial outcome: Actionable and not yet addressed because the runner has no `uv`.

Final outcome: Addressed by installing pinned uv `0.9.26` with architecture-specific checksums before the gate.

Local evidence: Workflow YAML, embedded shell syntax, repository scripts, and the complete repository gate were validated before push.

### Swift arm64

Initial outcome: Actionable and not yet addressed because the runner provides Swift 6.1 while the package requires Swift 6.2.

Final outcome: Addressed by installing pinned Swift `6.2.0` and asserting the active version before building.

Local evidence: The strict arm64 build and complete 171-test suite passed before push.

### Swift x86_64

Initial outcome: Actionable and not yet addressed because the runner provides Swift 6.1 while the package requires Swift 6.2.

Final outcome: Addressed by installing pinned Swift `6.2.0` on the Intel runner and asserting both version and architecture.

Local evidence: The workflow uses the same strict build and test commands as the verified local gate, while hosted Intel execution is verified by the post-push check.
