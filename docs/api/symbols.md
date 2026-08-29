# Public Swift symbols

This file is generated from Swift symbol graphs.
It lists every public declaration included in the release libraries.
Regenerate it with `uv run python scripts/generate-api-docs.py`.

## ZetaAI

| Symbol | Kind |
| --- | --- |
| `AssistantEvent.done(reason:message:)` | Case |
| `AssistantEvent.error(reason:message:)` | Case |
| `AssistantEvent.start(_:)` | Case |
| `AssistantEvent.textDelta(index:delta:partial:)` | Case |
| `AssistantEvent.textEnd(index:content:partial:)` | Case |
| `AssistantEvent.textStart(index:partial:)` | Case |
| `AssistantEvent.thinkingDelta(index:delta:partial:)` | Case |
| `AssistantEvent.thinkingEnd(index:content:partial:)` | Case |
| `AssistantEvent.thinkingStart(index:partial:)` | Case |
| `AssistantEvent.toolCallDelta(index:delta:partial:)` | Case |
| `AssistantEvent.toolCallEnd(index:call:partial:)` | Case |
| `AssistantEvent.toolCallStart(index:partial:)` | Case |
| `CacheRetention.long` | Case |
| `CacheRetention.none` | Case |
| `CacheRetention.short` | Case |
| `ContentBlock.image(data:mimeType:)` | Case |
| `ContentBlock.text(text:signature:)` | Case |
| `ContentBlock.thinking(text:signature:redacted:)` | Case |
| `ContentBlock.toolCall(_:)` | Case |
| `ImageStopReason.aborted` | Case |
| `ImageStopReason.error` | Case |
| `ImageStopReason.stop` | Case |
| `Message.assistant(_:)` | Case |
| `Message.custom(_:)` | Case |
| `Message.toolResult(_:)` | Case |
| `Message.user(_:)` | Case |
| `ModelCatalogError.invalidModel(_:)` | Case |
| `ModelCatalogError.missingResource` | Case |
| `ProviderError.http(status:body:)` | Case |
| `ProviderError.invalidResponse(_:)` | Case |
| `ProviderError.missingCredential(_:)` | Case |
| `ProviderError.unknownModel(_:)` | Case |
| `ProviderError.unknownProvider(_:)` | Case |
| `StopReason.aborted` | Case |
| `StopReason.deferred` | Case |
| `StopReason.error` | Case |
| `StopReason.length` | Case |
| `StopReason.pending` | Case |
| `StopReason.stop` | Case |
| `StopReason.toolUse` | Case |
| `ThinkingLevel.high` | Case |
| `ThinkingLevel.low` | Case |
| `ThinkingLevel.max` | Case |
| `ThinkingLevel.medium` | Case |
| `ThinkingLevel.minimal` | Case |
| `ThinkingLevel.off` | Case |
| `ThinkingLevel.xhigh` | Case |
| `AssistantEventStream` | Class |
| `CodexWebSocketPool` | Class |
| `DynamicModelProvider` | Class |
| `FileModelCatalogStore` | Class |
| `InMemoryModelCatalogStore` | Class |
| `ModelRegistry` | Class |
| `AssistantEvent` | Enumeration |
| `BuiltinProviderFactory` | Enumeration |
| `CacheRetention` | Enumeration |
| `CodexWebSocket` | Enumeration |
| `ContentBlock` | Enumeration |
| `ImageStopReason` | Enumeration |
| `Message` | Enumeration |
| `MessageTransforms` | Enumeration |
| `ModelCatalogError` | Enumeration |
| `ModelRefresh` | Enumeration |
| `ProviderError` | Enumeration |
| `ProviderPayloadBuilder` | Enumeration |
| `StopReason` | Enumeration |
| `ThinkingLevel` | Enumeration |
| `init()` | Initializer |
| `init(_:)` | Initializer |
| `init(_:timestamp:)` | Initializer |
| `init(account:sessionID:)` | Initializer |
| `init(apiKey:bearerToken:headers:temperature:maximumTokens:thinking:sessionID:timeout:cacheRetention:environment:transformHeaders:)` | Initializer |
| `init(apiKey:headers:temperature:maximumTokens:thinking:sessionID:timeout:cacheRetention:environment:transformHeaders:)` | Initializer |
| `init(bufferingPolicy:)` | Initializer |
| `init(configuration:session:environment:)` | Initializer |
| `init(content:api:provider:model:usage:stopReason:errorMessage:timestamp:)` | Initializer |
| `init(content:timestamp:)` | Initializer |
| `init(data:)` | Initializer |
| `init(from:)` | Initializer |
| `init(id:api:baseURL:models:apiKeyEnvironmentVariables:defaultHeaders:)` | Initializer |
| `init(id:initialModels:store:fetch:stream:)` | Initializer |
| `init(id:models:pool:environment:)` | Initializer |
| `init(id:models:tokensPerSecond:)` | Initializer |
| `init(id:name:api:provider:baseURL:input:output:cost:)` | Initializer |
| `init(id:name:api:provider:baseURL:reasoning:input:cost:contextWindow:maximumTokens:)` | Initializer |
| `init(id:name:api:provider:baseURL:reasoning:input:cost:contextWindow:maximumTokens:headers:compat:thinkingLevelMap:baseURLTemplate:)` | Initializer |
| `init(id:name:arguments:thoughtSignature:namespace:)` | Initializer |
| `init(idleTimeout:factory:)` | Initializer |
| `init(input:output:cacheRead:cacheWrite:)` | Initializer |
| `init(input:output:cacheRead:cacheWrite:cacheWrite1h:reasoning:totalTokens:cost:)` | Initializer |
| `init(model:)` | Initializer |
| `init(models:lastModified:checkedAt:etag:)` | Initializer |
| `init(models:session:environment:)` | Initializer |
| `init(name:description:parameters:)` | Initializer |
| `init(provider:modelID:api:id:expiresAt:pollAfterMilliseconds:data:)` | Initializer |
| `init(rawValue:)` | Initializer |
| `init(role:content:timestamp:)` | Initializer |
| `init(systemPrompt:messages:tools:)` | Initializer |
| `init(task:)` | Initializer |
| `init(toolCallId:toolName:content:details:usage:addedToolNames:isError:timestamp:)` | Initializer |
| `init(url:)` | Initializer |
| `allModels()` | Instance Method |
| `allProviders()` | Instance Method |
| `attachProducer(_:)` | Instance Method |
| `callCount()` | Instance Method |
| `calls()` | Instance Method |
| `cancel(api:provider:model:)` | Instance Method |
| `close()` | Instance Method |
| `closeAll()` | Instance Method |
| `compatibility(_:)` | Instance Method |
| `compatibilityBool(_:)` | Instance Method |
| `compatibilityString(_:)` | Instance Method |
| `consume(_:eventName:)` | Instance Method |
| `count()` | Instance Method |
| `delete(provider:)` | Instance Method |
| `emit(_:)` | Instance Method |
| `encode(to:)` | Instance Method |
| `enqueue(_:)` | Instance Method |
| `evictIdle(now:)` | Instance Method |
| `failBeforeStart(api:provider:model:error:aborted:)` | Instance Method |
| `finish()` | Instance Method |
| `generate(model:input:options:)` | Instance Method |
| `makeAsyncIterator()` | Instance Method |
| `merge(_:)` | Instance Method |
| `model(provider:id:)` | Instance Method |
| `pendingCount()` | Instance Method |
| `provider(_:)` | Instance Method |
| `push(_:)` | Instance Method |
| `read(provider:)` | Instance Method |
| `receive()` | Instance Method |
| `refresh(allowNetwork:)` | Instance Method |
| `remove(_:)` | Instance Method |
| `requestThinkingValue(_:)` | Instance Method |
| `resolvedThinkingLevel(_:)` | Instance Method |
| `restore()` | Instance Method |
| `result()` | Instance Method |
| `send(_:)` | Instance Method |
| `set(_:)` | Instance Method |
| `stream(model:context:options:)` | Instance Method |
| `thinkingLevelMapValue(_:)` | Instance Method |
| `withConnection(key:url:headers:operation:)` | Instance Method |
| `write(provider:entry:)` | Instance Method |
| `aborted` | Instance Property |
| `account` | Instance Property |
| `addedToolNames` | Instance Property |
| `api` | Instance Property |
| `apiKey` | Instance Property |
| `apiKeyEnvironmentVariables` | Instance Property |
| `arguments` | Instance Property |
| `baseURL` | Instance Property |
| `baseURLTemplate` | Instance Property |
| `bearerToken` | Instance Property |
| `cacheRead` | Instance Property |
| `cacheRetention` | Instance Property |
| `cacheWrite` | Instance Property |
| `cacheWrite1h` | Instance Property |
| `checkedAt` | Instance Property |
| `compat` | Instance Property |
| `configuration` | Instance Property |
| `content` | Instance Property |
| `contextWindow` | Instance Property |
| `cost` | Instance Property |
| `data` | Instance Property |
| `defaultHeaders` | Instance Property |
| `deferred` | Instance Property |
| `description` | Instance Property |
| `details` | Instance Property |
| `dictionary` | Instance Property |
| `endTurn` | Instance Property |
| `environment` | Instance Property |
| `errorDescription` | Instance Property |
| `errorMessage` | Instance Property |
| `errors` | Instance Property |
| `etag` | Instance Property |
| `event` | Instance Property |
| `expiresAt` | Instance Property |
| `headers` | Instance Property |
| `id` | Instance Property |
| `identifier` | Instance Property |
| `input` | Instance Property |
| `isError` | Instance Property |
| `lastModified` | Instance Property |
| `maximumTokens` | Instance Property |
| `message` | Instance Property |
| `messageCount` | Instance Property |
| `messages` | Instance Property |
| `model` | Instance Property |
| `modelDefinitions` | Instance Property |
| `modelID` | Instance Property |
| `models` | Instance Property |
| `modelsByProvider` | Instance Property |
| `name` | Instance Property |
| `namespace` | Instance Property |
| `output` | Instance Property |
| `parameters` | Instance Property |
| `partial` | Instance Property |
| `pollAfterMilliseconds` | Instance Property |
| `provider` | Instance Property |
| `providers` | Instance Property |
| `rawStopReason` | Instance Property |
| `reasoning` | Instance Property |
| `refreshed` | Instance Property |
| `responseID` | Instance Property |
| `responseId` | Instance Property |
| `responseModel` | Instance Property |
| `role` | Instance Property |
| `sessionID` | Instance Property |
| `stopReason` | Instance Property |
| `systemPrompt` | Instance Property |
| `temperature` | Instance Property |
| `thinking` | Instance Property |
| `thinkingLevelMap` | Instance Property |
| `thoughtSignature` | Instance Property |
| `timeout` | Instance Property |
| `timestamp` | Instance Property |
| `toolCallId` | Instance Property |
| `toolName` | Instance Property |
| `tools` | Instance Property |
| `total` | Instance Property |
| `totalTokens` | Instance Property |
| `transformHeaders` | Instance Property |
| `type` | Instance Property |
| `usage` | Instance Property |
| `subscript(_:)` | Instance Subscript |
| `AIProvider` | Protocol |
| `ImageProvider` | Protocol |
| `ModelCatalogStore` | Protocol |
| `WebSocketConnection` | Protocol |
| `AssistantImages` | Structure |
| `AssistantMessage` | Structure |
| `BuiltinModelCatalog` | Structure |
| `CaseInsensitiveHeaders` | Structure |
| `CodexWebSocketPool.Key` | Structure |
| `CodexWebSocketProvider` | Structure |
| `Context` | Structure |
| `Cost` | Structure |
| `CustomAgentMessage` | Structure |
| `DeferredHandle` | Structure |
| `FauxCall` | Structure |
| `FauxProvider` | Structure |
| `HTTPProvider` | Structure |
| `ImageModel` | Structure |
| `Model` | Structure |
| `ModelCost` | Structure |
| `ModelRefreshResult` | Structure |
| `OpenRouterImageProvider` | Structure |
| `ProviderConfiguration` | Structure |
| `ProviderEventReducer` | Structure |
| `SSEDecoder` | Structure |
| `SSERecord` | Structure |
| `StoredModelCatalog` | Structure |
| `StreamOptions` | Structure |
| `StreamProtocolError` | Structure |
| `ToolCall` | Structure |
| `ToolDefinition` | Structure |
| `ToolResultMessage` | Structure |
| `URLSessionWebSocketConnection` | Structure |
| `Usage` | Structure |
| `UserMessage` | Structure |
| `APIID` | Type Alias |
| `AssistantEventStream.AsyncIterator` | Type Alias |
| `AssistantEventStream.Element` | Type Alias |
| `DynamicModelProvider.Fetch` | Type Alias |
| `DynamicModelProvider.Stream` | Type Alias |
| `HeaderTransform` | Type Alias |
| `ProviderID` | Type Alias |
| `WebSocketFactory` | Type Alias |
| `all(_:allowNetwork:)` | Type Method |
| `build(model:context:options:)` | Type Method |
| `bundled()` | Type Method |
| `classifyOverflow(status:message:)` | Type Method |
| `defaultFactory(session:)` | Type Method |
| `estimateContextTokens(_:)` | Type Method |
| `forModel(_:target:knownTools:)` | Type Method |
| `normalizeToolCallID(_:)` | Type Method |
| `providers(catalog:session:)` | Type Method |
| `retryDelay(attempt:baseMilliseconds:requestedMilliseconds:maximumRequestedMilliseconds:)` | Type Method |
| `environmentVariables` | Type Property |

## ZetaAgent

| Symbol | Kind |
| --- | --- |
| `AgentError.alreadyRunning` | Case |
| `AgentError.blocked(_:)` | Case |
| `AgentError.invalidContinuation` | Case |
| `AgentError.unknownTool(_:)` | Case |
| `AgentEvent.agentEnd(_:)` | Case |
| `AgentEvent.agentStart` | Case |
| `AgentEvent.messageEnd(_:)` | Case |
| `AgentEvent.messageStart(_:)` | Case |
| `AgentEvent.messageUpdate(_:_:)` | Case |
| `AgentEvent.toolExecutionEnd(id:name:result:isError:)` | Case |
| `AgentEvent.toolExecutionStart(id:name:arguments:)` | Case |
| `AgentEvent.toolExecutionUpdate(id:name:result:)` | Case |
| `AgentEvent.turnEnd(_:_:)` | Case |
| `AgentEvent.turnStart` | Case |
| `QueueDeliveryMode.all` | Case |
| `QueueDeliveryMode.oneAtATime` | Case |
| `ToolExecutionMode.parallel` | Case |
| `ToolExecutionMode.sequential` | Case |
| `Agent` | Class |
| `AgentError` | Enumeration |
| `AgentEvent` | Enumeration |
| `QueueDeliveryMode` | Enumeration |
| `ToolExecutionMode` | Enumeration |
| `init(content:details:usage:addedToolNames:terminate:)` | Initializer |
| `init(definition:label:executionMode:parameterSchema:prepareArguments:execute:)` | Initializer |
| `init(rawValue:)` | Initializer |
| `init(state:toolExecutionMode:stream:)` | Initializer |
| `init(systemPrompt:model:thinkingLevel:tools:messages:)` | Initializer |
| `abort()` | Instance Method |
| `abortRetry()` | Instance Method |
| `clearQueues()` | Instance Method |
| `compact(summaryPrompt:retainedTail:)` | Instance Method |
| `configureRetry(maximumRetries:baseDelayMilliseconds:)` | Instance Method |
| `configureRetry(maximumRetries:baseDelayMilliseconds:maximumDelayMilliseconds:)` | Instance Method |
| `continue()` | Instance Method |
| `followUp(_:)` | Instance Method |
| `prompt(_:)` | Instance Method |
| `reset()` | Instance Method |
| `setAfterToolCall(_:)` | Instance Method |
| `setBeforeToolCall(_:)` | Instance Method |
| `setFollowUpMode(_:)` | Instance Method |
| `setMessages(_:)` | Instance Method |
| `setModel(_:)` | Instance Method |
| `setPrepareNextTurn(_:)` | Instance Method |
| `setShouldStopAfterTurn(_:)` | Instance Method |
| `setSteeringMode(_:)` | Instance Method |
| `setThinkingLevel(_:)` | Instance Method |
| `setTools(_:)` | Instance Method |
| `setTransformContext(_:)` | Instance Method |
| `state()` | Instance Method |
| `steer(_:)` | Instance Method |
| `subscribe(_:)` | Instance Method |
| `unsubscribe(_:)` | Instance Method |
| `waitForIdle()` | Instance Method |
| `addedToolNames` | Instance Property |
| `afterToolCall` | Instance Property |
| `beforeToolCall` | Instance Property |
| `content` | Instance Property |
| `definition` | Instance Property |
| `details` | Instance Property |
| `errorDescription` | Instance Property |
| `errorMessage` | Instance Property |
| `execute` | Instance Property |
| `executionMode` | Instance Property |
| `followUpMode` | Instance Property |
| `isStreaming` | Instance Property |
| `label` | Instance Property |
| `maximumRetries` | Instance Property |
| `messages` | Instance Property |
| `model` | Instance Property |
| `parameterSchema` | Instance Property |
| `pendingToolCalls` | Instance Property |
| `prepareArguments` | Instance Property |
| `prepareNextTurn` | Instance Property |
| `retryBaseDelayMilliseconds` | Instance Property |
| `retryMaximumDelayMilliseconds` | Instance Property |
| `shouldStopAfterTurn` | Instance Property |
| `steeringMode` | Instance Property |
| `streamingMessage` | Instance Property |
| `systemPrompt` | Instance Property |
| `terminate` | Instance Property |
| `thinkingLevel` | Instance Property |
| `toolExecutionMode` | Instance Property |
| `tools` | Instance Property |
| `transformContext` | Instance Property |
| `usage` | Instance Property |
| `AgentState` | Structure |
| `AgentTool` | Structure |
| `AgentToolResult` | Structure |
| `Agent.StreamFunction` | Type Alias |
| `Agent.Subscriber` | Type Alias |

## ZetaAuth

| Symbol | Kind |
| --- | --- |
| `AWSSignatureError.invalidURL` | Case |
| `AWSSignatureError.missingHost` | Case |
| `CredentialResolverError.invalidTokenResponse` | Case |
| `CredentialResolverError.unsupportedServiceAccount` | Case |
| `DeviceTokenPollResult.authorized(_:)` | Case |
| `DeviceTokenPollResult.denied(_:)` | Case |
| `DeviceTokenPollResult.pending` | Case |
| `DeviceTokenPollResult.slowDown` | Case |
| `OAuthError.denied(_:)` | Case |
| `OAuthError.expired` | Case |
| `OAuthError.invalidCallback` | Case |
| `OAuthError.invalidVerifier` | Case |
| `OAuthError.randomFailure` | Case |
| `DeviceAuthorizationPoller` | Class |
| `OAuthCallbackServer` | Class |
| `SerializedCredentialRefresh` | Class |
| `AWSSignatureError` | Enumeration |
| `AWSSignatureV4` | Enumeration |
| `CredentialResolver` | Enumeration |
| `CredentialResolverError` | Enumeration |
| `DeviceTokenPollResult` | Enumeration |
| `OAuthError` | Enumeration |
| `init()` | Initializer |
| `init(access:refresh:expires:extra:)` | Initializer |
| `init(accessKeyID:secretAccessKey:sessionToken:)` | Initializer |
| `init(apiKey:bearerToken:headers:source:)` | Initializer |
| `init(deviceCode:userCode:verificationURI:expiresIn:interval:)` | Initializer |
| `init(expectedState:)` | Initializer |
| `init(from:)` | Initializer |
| `init(sleep:)` | Initializer |
| `init(verifier:)` | Initializer |
| `poll(authorization:operation:)` | Instance Method |
| `refresh(provider:operation:)` | Instance Method |
| `requiresRefresh(nowMilliseconds:minimumValidityMilliseconds:)` | Instance Method |
| `start()` | Instance Method |
| `stop()` | Instance Method |
| `waitForCallback()` | Instance Method |
| `access` | Instance Property |
| `accessKeyID` | Instance Property |
| `apiKey` | Instance Property |
| `bearerToken` | Instance Property |
| `canonicalRequest` | Instance Property |
| `challenge` | Instance Property |
| `code` | Instance Property |
| `deviceCode` | Instance Property |
| `errorDescription` | Instance Property |
| `expires` | Instance Property |
| `expiresIn` | Instance Property |
| `extra` | Instance Property |
| `headers` | Instance Property |
| `interval` | Instance Property |
| `refresh` | Instance Property |
| `request` | Instance Property |
| `secretAccessKey` | Instance Property |
| `sessionToken` | Instance Property |
| `signature` | Instance Property |
| `source` | Instance Property |
| `state` | Instance Property |
| `stringToSign` | Instance Property |
| `userCode` | Instance Property |
| `verificationURI` | Instance Property |
| `verifier` | Instance Property |
| `AWSCredential` | Structure |
| `AWSSignedRequest` | Structure |
| `DeviceAuthorization` | Structure |
| `OAuthCallback` | Structure |
| `OAuthCredential` | Structure |
| `PKCEChallenge` | Structure |
| `ResolvedAuthentication` | Structure |
| `DeviceAuthorizationPoller.Poll` | Type Alias |
| `apiKey(explicit:stored:environment:variables:)` | Type Method |
| `aws(environment:)` | Type Method |
| `random()` | Type Method |
| `sign(request:body:service:region:credential:date:)` | Type Method |
| `vertex(explicitAPIKey:environment:)` | Type Method |
| `vertexAccessAuthentication(explicitAPIKey:environment:session:)` | Type Method |

## ZetaBedrock

| Symbol | Kind |
| --- | --- |
| `AWSEventStreamError.invalidCRC` | Case |
| `AWSEventStreamError.invalidHeader` | Case |
| `AWSEventStreamError.invalidLength` | Case |
| `AWSEventStreamError.truncated` | Case |
| `AWSEventStreamError` | Enumeration |
| `init()` | Initializer |
| `init(maximumMessageLength:)` | Initializer |
| `init(models:region:session:credential:)` | Initializer |
| `finish()` | Instance Method |
| `push(_:)` | Instance Method |
| `stream(model:context:options:)` | Instance Method |
| `headers` | Instance Property |
| `id` | Instance Property |
| `modelDefinitions` | Instance Property |
| `models` | Instance Property |
| `payload` | Instance Property |
| `AWSEventStreamDecoder` | Structure |
| `AWSEventStreamMessage` | Structure |
| `BedrockProvider` | Structure |
| `defaultMaximumMessageLength` | Type Property |

## ZetaCLI

| Symbol | Kind |
| --- | --- |
| `CLIArgumentError.conflict(_:)` | Case |
| `CLIArgumentError.invalidValue(_:)` | Case |
| `CLIArgumentError.missingValue(_:)` | Case |
| `CLIArgumentError.unknownShortFlag(_:)` | Case |
| `CLIMode.interactive` | Case |
| `CLIMode.json` | Case |
| `CLIMode.print` | Case |
| `CLIMode.rpc` | Case |
| `CLIRPCRuntime` | Class |
| `CLIArgumentError` | Enumeration |
| `CLIMode` | Enumeration |
| `ZetaCLI` | Enumeration |
| `init(rawValue:)` | Initializer |
| `effectiveMode(stdinIsTTY:stdoutIsTTY:)` | Instance Method |
| `handle(_:)` | Instance Method |
| `apiKey` | Instance Property |
| `approve` | Instance Property |
| `continueSession` | Instance Property |
| `errorDescription` | Instance Property |
| `excludedTools` | Instance Property |
| `extensionFlags` | Instance Property |
| `files` | Instance Property |
| `fork` | Instance Property |
| `help` | Instance Property |
| `listModels` | Instance Property |
| `messages` | Instance Property |
| `mode` | Instance Property |
| `model` | Instance Property |
| `name` | Instance Property |
| `noBuiltinTools` | Instance Property |
| `noSession` | Instance Property |
| `noTools` | Instance Property |
| `offline` | Instance Property |
| `print` | Instance Property |
| `provider` | Instance Property |
| `resume` | Instance Property |
| `session` | Instance Property |
| `sessionDirectory` | Instance Property |
| `sessionID` | Instance Property |
| `thinking` | Instance Property |
| `thinkingSpecified` | Instance Property |
| `tools` | Instance Property |
| `version` | Instance Property |
| `CLIArguments` | Structure |
| `parse(_:)` | Type Method |
| `run(arguments:)` | Type Method |
| `runWithSignals(arguments:)` | Type Method |
| `help` | Type Property |
| `version` | Type Property |

## ZetaClient

| Symbol | Kind |
| --- | --- |
| `ClientConnectionState.connected` | Case |
| `ClientConnectionState.connecting` | Case |
| `ClientConnectionState.disconnected` | Case |
| `LeaseMode.exclusive` | Case |
| `LeaseMode.shared` | Case |
| `PiClientError.detached` | Case |
| `PiClientError.disconnected` | Case |
| `PiClientError.disposed` | Case |
| `PiClientError.ownership` | Case |
| `PiClientError.protocolFailure(_:)` | Case |
| `PiClientError.server(_:)` | Case |
| `PiClient` | Class |
| `SessionLease` | Class |
| `ClientConnectionState` | Enumeration |
| `LeaseMode` | Enumeration |
| `PiClientError` | Enumeration |
| `init(maximumFrameLength:handshakeTimeout:transportFactory:)` | Initializer |
| `init(maximumFrameLength:transportFactory:)` | Initializer |
| `init(onData:onClose:onError:)` | Initializer |
| `init(rawValue:)` | Initializer |
| `abort()` | Instance Method |
| `acquireSession(_:mode:)` | Instance Method |
| `attachSession(_:)` | Instance Method |
| `close()` | Instance Method |
| `connect()` | Instance Method |
| `connectionState()` | Instance Method |
| `createSession(_:)` | Instance Method |
| `detach()` | Instance Method |
| `disconnect()` | Instance Method |
| `dispose()` | Instance Method |
| `listSessions()` | Instance Method |
| `prompt(_:)` | Instance Method |
| `reconnect()` | Instance Method |
| `send(_:)` | Instance Method |
| `sessionSnapshot(_:)` | Instance Method |
| `setModel(_:)` | Instance Method |
| `setThinking(_:)` | Instance Method |
| `snapshot()` | Instance Method |
| `steer(_:)` | Instance Method |
| `subscribeEvents(_:)` | Instance Method |
| `subscribeSnapshots(_:)` | Instance Method |
| `unsubscribe(_:)` | Instance Method |
| `errorDescription` | Instance Property |
| `id` | Instance Property |
| `mode` | Instance Property |
| `onClose` | Instance Property |
| `onData` | Instance Property |
| `onError` | Instance Property |
| `sessionID` | Instance Property |
| `ByteTransport` | Protocol |
| `ByteTransportHandlers` | Structure |
| `ByteTransportFactory` | Type Alias |

## ZetaCompaction

| Symbol | Kind |
| --- | --- |
| `Compaction` | Enumeration |
| `init(reserveTokens:keepRecentTokens:toolResultMaximumCharacters:)` | Initializer |
| `estimatedTokensBefore` | Instance Property |
| `firstRetainedMessageIndex` | Instance Property |
| `keepRecentTokens` | Instance Property |
| `messagesToSummarize` | Instance Property |
| `reserveTokens` | Instance Property |
| `retainedTail` | Instance Property |
| `toolResultMaximumCharacters` | Instance Property |
| `CompactionPreparation` | Structure |
| `CompactionSettings` | Structure |
| `branchSummaryPrompt(abandonedMessages:tokenBudget:)` | Type Method |
| `estimateTokens(_:)` | Type Method |
| `prepare(messages:settings:)` | Type Method |
| `shouldCompact(messages:contextWindow:reserveTokens:)` | Type Method |
| `summaryPrompt(preparation:customInstructions:toolResultMaximumCharacters:)` | Type Method |

## ZetaConfig

| Symbol | Kind |
| --- | --- |
| `ProjectTrustDefault.always` | Case |
| `ProjectTrustDefault.ask` | Case |
| `ProjectTrustDefault.never` | Case |
| `QueueMode.all` | Case |
| `QueueMode.oneAtATime` | Case |
| `StoredCredential.apiKey(key:environment:)` | Case |
| `StoredCredential.oauth(access:refresh:expires:extras:)` | Case |
| `TransportPreference.auto` | Case |
| `TransportPreference.sse` | Case |
| `TransportPreference.websocket` | Case |
| `TrustDecision.denied` | Case |
| `TrustDecision.trusted` | Case |
| `AuthStore` | Class |
| `SettingsStore` | Class |
| `TrustStore` | Class |
| `ProjectTrustDefault` | Enumeration |
| `QueueMode` | Enumeration |
| `StoredCredential` | Enumeration |
| `TransportPreference` | Enumeration |
| `TrustDecision` | Enumeration |
| `withAdvisoryFileLock(url:operation:)` | Function |
| `init()` | Initializer |
| `init(apiKey:bearerToken:environment:)` | Initializer |
| `init(from:)` | Initializer |
| `init(home:workingDirectory:environment:)` | Initializer |
| `init(paths:includeProject:)` | Initializer |
| `init(rawValue:)` | Initializer |
| `init(url:)` | Initializer |
| `current()` | Instance Method |
| `decision(for:)` | Instance Method |
| `delete(provider:)` | Instance Method |
| `drainErrors()` | Instance Method |
| `encode(to:)` | Instance Method |
| `flush()` | Instance Method |
| `list()` | Instance Method |
| `modify(_:)` | Instance Method |
| `read(provider:)` | Instance Method |
| `resolveAPIKey(provider:environment:fallbackVariables:)` | Instance Method |
| `resolveCredential(provider:environment:fallbackVariables:nowMilliseconds:)` | Instance Method |
| `set(_:for:)` | Instance Method |
| `set(provider:credential:)` | Instance Method |
| `agentDirectory` | Instance Property |
| `apiKey` | Instance Property |
| `auth` | Instance Property |
| `autocompleteMaxVisible` | Instance Property |
| `baseDelayMs` | Instance Property |
| `bearerToken` | Instance Property |
| `blockImages` | Instance Property |
| `compaction` | Instance Property |
| `defaultProjectTrust` | Instance Property |
| `editorPadding` | Instance Property |
| `enableInstallTelemetry` | Instance Property |
| `enabled` | Instance Property |
| `environment` | Instance Property |
| `followUpMode` | Instance Property |
| `fullscreenCopyOnSelect` | Instance Property |
| `fullscreenExit` | Instance Property |
| `fullscreenScrollbar` | Instance Property |
| `globalSettings` | Instance Property |
| `home` | Instance Property |
| `httpIdleTimeoutMs` | Instance Property |
| `imageAutoResize` | Instance Property |
| `imageWidth` | Instance Property |
| `keepRecentTokens` | Instance Property |
| `kind` | Instance Property |
| `maxRetries` | Instance Property |
| `maxRetryDelayMs` | Instance Property |
| `outputPadding` | Instance Property |
| `projectSettings` | Instance Property |
| `reserveTokens` | Instance Property |
| `retry` | Instance Property |
| `sessions` | Instance Property |
| `showImages` | Instance Property |
| `steeringMode` | Instance Property |
| `theme` | Instance Property |
| `transport` | Instance Property |
| `trust` | Instance Property |
| `tuiMode` | Instance Property |
| `workingDirectory` | Instance Property |
| `CompactionSettings` | Structure |
| `ResolvedStoredCredential` | Structure |
| `RetrySettings` | Structure |
| `Settings` | Structure |
| `ZetaPaths` | Structure |
| `loadMerged(globalURL:projectURL:)` | Type Method |
| `merge(global:project:)` | Type Method |

## ZetaCore

| Symbol | Kind |
| --- | --- |
| `JSONError.Code.duplicateKey` | Case |
| `JSONError.Code.invalidNumber` | Case |
| `JSONError.Code.invalidSyntax` | Case |
| `JSONError.Code.invalidUTF8` | Case |
| `JSONError.Code.limitExceeded` | Case |
| `JSONError.Code.nonFiniteNumber` | Case |
| `JSONError.Code.trailingData` | Case |
| `JSONError.Code.typeMismatch` | Case |
| `JSONSchema.allOf(_:)` | Case |
| `JSONSchema.any` | Case |
| `JSONSchema.anyOf(_:)` | Case |
| `JSONSchema.array(items:minItems:maxItems:)` | Case |
| `JSONSchema.boolean` | Case |
| `JSONSchema.enumeration(_:)` | Case |
| `JSONSchema.integer(minimum:maximum:javascriptSafe:)` | Case |
| `JSONSchema.null` | Case |
| `JSONSchema.number(minimum:maximum:)` | Case |
| `JSONSchema.object(properties:additionalProperties:)` | Case |
| `JSONSchema.oneOf(_:)` | Case |
| `JSONSchema.string(minLength:maxLength:pattern:)` | Case |
| `JSONSchema.tuple(items:additionalItems:)` | Case |
| `JSONSchemaAdditionalProperties.allowed` | Case |
| `JSONSchemaAdditionalProperties.forbidden` | Case |
| `JSONSchemaAdditionalProperties.schema(_:)` | Case |
| `JSONValue.array(_:)` | Case |
| `JSONValue.bool(_:)` | Case |
| `JSONValue.null` | Case |
| `JSONValue.number(_:)` | Case |
| `JSONValue.object(_:)` | Case |
| `JSONValue.string(_:)` | Case |
| `PrimitiveValidationError.invalidBase64` | Case |
| `PrimitiveValidationError.invalidRandomByteCount` | Case |
| `PrimitiveValidationError.invalidUUIDv7` | Case |
| `PrimitiveValidationError.timestampOutOfRange` | Case |
| `ValidationIssue.Code.ambiguousUnion` | Case |
| `ValidationIssue.Code.invalidFormat` | Case |
| `ValidationIssue.Code.invalidValue` | Case |
| `ValidationIssue.Code.missingProperty` | Case |
| `ValidationIssue.Code.noUnionMatch` | Case |
| `ValidationIssue.Code.outOfRange` | Case |
| `ValidationIssue.Code.typeMismatch` | Case |
| `ValidationIssue.Code.unknownProperty` | Case |
| `ValidationMode.complete` | Case |
| `ValidationMode.partial` | Case |
| `UUIDv7Generator` | Class |
| `JSONError.Code` | Enumeration |
| `JSONSchema` | Enumeration |
| `JSONSchemaAdditionalProperties` | Enumeration |
| `JSONValue` | Enumeration |
| `OrderedJSON` | Enumeration |
| `PrimitiveValidationError` | Enumeration |
| `StrictValue` | Enumeration |
| `ValidationIssue.Code` | Enumeration |
| `ValidationMode` | Enumeration |
| `uuidv7()` | Function |
| `javaScriptMaximumSafeInteger` | Global Variable |
| `javaScriptMinimumSafeInteger` | Global Variable |
| `init()` | Initializer |
| `init(_:)` | Initializer |
| `init(_:_:offset:)` | Initializer |
| `init(_:_:required:)` | Initializer |
| `init(_:path:)` | Initializer |
| `init(arrayLiteral:)` | Initializer |
| `init(booleanLiteral:)` | Initializer |
| `init(clock:randomBytes:)` | Initializer |
| `init(code:path:message:)` | Initializer |
| `init(data:)` | Initializer |
| `init(date:)` | Initializer |
| `init(dictionaryLiteral:)` | Initializer |
| `init(floatLiteral:)` | Initializer |
| `init(from:)` | Initializer |
| `init(integerLiteral:)` | Initializer |
| `init(key:value:)` | Initializer |
| `init(maximumByteCount:maximumContainerCount:maximumDepth:)` | Initializer |
| `init(name:message:)` | Initializer |
| `init(nilLiteral:)` | Initializer |
| `init(prettyPrinted:sortedKeys:)` | Initializer |
| `init(rawValue:)` | Initializer |
| `init(stringLiteral:)` | Initializer |
| `init(validating:)` | Initializer |
| `accepts(_:mode:)` | Instance Method |
| `append(key:value:)` | Instance Method |
| `childPath(_:)` | Instance Method |
| `encode(to:)` | Instance Method |
| `finish()` | Instance Method |
| `hash(into:)` | Instance Method |
| `index(after:)` | Instance Method |
| `index(before:)` | Instance Method |
| `next()` | Instance Method |
| `optional(_:)` | Instance Method |
| `required(_:)` | Instance Method |
| `validate(_:mode:coerce:)` | Instance Method |
| `code` | Instance Property |
| `data` | Instance Property |
| `date` | Instance Property |
| `description` | Instance Property |
| `doubleValue` | Instance Property |
| `endIndex` | Instance Property |
| `entries` | Instance Property |
| `isInteger` | Instance Property |
| `isJavaScriptSafeInteger` | Instance Property |
| `issues` | Instance Property |
| `key` | Instance Property |
| `keys` | Instance Property |
| `maximumByteCount` | Instance Property |
| `maximumContainerCount` | Instance Property |
| `maximumDepth` | Instance Property |
| `message` | Instance Property |
| `name` | Instance Property |
| `object` | Instance Property |
| `offset` | Instance Property |
| `path` | Instance Property |
| `prettyPrinted` | Instance Property |
| `rawValue` | Instance Property |
| `remainingKeys` | Instance Property |
| `required` | Instance Property |
| `safeIntegerValue` | Instance Property |
| `schema` | Instance Property |
| `sortedKeys` | Instance Property |
| `startIndex` | Instance Property |
| `timestamp` | Instance Property |
| `value` | Instance Property |
| `subscript(_:)` | Instance Subscript |
| `<(_:_:)` | Operator |
| `==(_:_:)` | Operator |
| `Base64Content` | Structure |
| `JSONError` | Structure |
| `JSONLimits` | Structure |
| `JSONNumber` | Structure |
| `JSONSchemaProperty` | Structure |
| `MillisecondTimestamp` | Structure |
| `NormalizedError` | Structure |
| `OrderedJSON.EncodingOptions` | Structure |
| `OrderedJSONObject` | Structure |
| `OrderedJSONObject.Entry` | Structure |
| `StrictObjectReader` | Structure |
| `UUIDv7` | Structure |
| `ValidationFailure` | Structure |
| `ValidationIssue` | Structure |
| `OrderedJSONObject.Index` | Type Alias |
| `UUIDv7Generator.Clock` | Type Alias |
| `UUIDv7Generator.RandomBytes` | Type Alias |
| `array(_:path:)` | Type Method |
| `boolean(_:path:)` | Type Method |
| `decode(_:limits:)` | Type Method |
| `encode(_:options:)` | Type Method |
| `finiteNumber(_:path:)` | Type Method |
| `normalize(_:maximumMessageLength:)` | Type Method |
| `safeInteger(_:path:minimum:maximum:)` | Type Method |
| `string(_:options:)` | Type Method |
| `string(_:path:nonempty:)` | Type Method |
| `default` | Type Property |
| `shared` | Type Property |

## ZetaEvals

| Symbol | Kind |
| --- | --- |
| `EvaluationRunner` | Class |
| `init(execute:)` | Initializer |
| `init(from:)` | Initializer |
| `init(id:prompt:requiredSubstrings:)` | Initializer |
| `run(cases:seed:)` | Instance Method |
| `id` | Instance Property |
| `missing` | Instance Property |
| `output` | Instance Property |
| `passed` | Instance Property |
| `prompt` | Instance Property |
| `requiredSubstrings` | Instance Property |
| `results` | Instance Property |
| `score` | Instance Property |
| `seed` | Instance Property |
| `total` | Instance Property |
| `EvaluationCase` | Structure |
| `EvaluationReport` | Structure |
| `EvaluationResult` | Structure |
| `EvaluationRunner.Execute` | Type Alias |

## ZetaExport

| Symbol | Kind |
| --- | --- |
| `SessionExporter` | Enumeration |
| `escapeHTML(_:)` | Type Method |
| `jsonLines(_:)` | Type Method |
| `safeURL(_:)` | Type Method |
| `standaloneHTML(title:sessionJSONL:renderedTranscript:leafID:)` | Type Method |
| `allowedURLSchemes` | Type Property |

## ZetaHarnessSessions

| Symbol | Kind |
| --- | --- |
| `HarnessMutation.entry(lane:_:)` | Case |
| `HarnessMutation.label(sequence:targetID:value:)` | Case |
| `HarnessMutation.lane(sequence:lane:leafID:)` | Case |
| `HarnessMutation.name(sequence:value:)` | Case |
| `HarnessMutation.record(_:)` | Case |
| `HarnessSessionError.duplicateID` | Case |
| `HarnessSessionError.invalidHeader` | Case |
| `HarnessSessionError.invalidMutation` | Case |
| `HarnessSessionError.missingEntry` | Case |
| `HarnessSessionError.missingLane` | Case |
| `HarnessSessionError.nonconsecutiveSequence` | Case |
| `HarnessSessionError.operationAlreadyOpen` | Case |
| `HarnessSessionError.unsupportedVersion` | Case |
| `HarnessSessionStorage` | Class |
| `HarnessEntryType` | Enumeration |
| `HarnessMutation` | Enumeration |
| `HarnessRecordType` | Enumeration |
| `HarnessSessionError` | Enumeration |
| `currentHarnessSessionVersion` | Global Variable |
| `init(header:)` | Initializer |
| `init(id:createdAt:cwd:parentSessionID:legacyParentSessionPath:metadata:)` | Initializer |
| `allMutations(after:limit:)` | Instance Method |
| `apply(_:)` | Instance Method |
| `branch(start:)` | Instance Method |
| `encodeJSONL()` | Instance Method |
| `entry(_:)` | Instance Method |
| `findEntries(type:newestFirst:afterSequence:limit:)` | Instance Method |
| `findRecords(lane:type:runID:newestFirst:afterSequence:limit:)` | Instance Method |
| `label(_:)` | Instance Method |
| `lane(_:)` | Instance Method |
| `openOperations(lane:)` | Instance Method |
| `sessionName()` | Instance Method |
| `createdAt` | Instance Property |
| `cwd` | Instance Property |
| `errorDescription` | Instance Property |
| `fields` | Instance Property |
| `header` | Instance Property |
| `id` | Instance Property |
| `json` | Instance Property |
| `lane` | Instance Property |
| `legacyParentSessionPath` | Instance Property |
| `metadata` | Instance Property |
| `parentID` | Instance Property |
| `parentSessionID` | Instance Property |
| `sequence` | Instance Property |
| `timestamp` | Instance Property |
| `type` | Instance Property |
| `HarnessEntry` | Structure |
| `HarnessRecord` | Structure |
| `HarnessSessionHeader` | Structure |
| `decode(_:)` | Type Method |
| `decodeJSONL(_:)` | Type Method |
| `all` | Type Property |

## ZetaMigration

| Symbol | Kind |
| --- | --- |
| `PiMigrationError.destinationNotEmpty` | Case |
| `PiMigrationError.invalidArtifact(_:)` | Case |
| `PiMigrationError.sourceMissing` | Case |
| `PiMigrationError` | Enumeration |
| `init(from:)` | Initializer |
| `init(source:destination:)` | Initializer |
| `migrate()` | Instance Method |
| `backupDirectory` | Instance Property |
| `copied` | Instance Property |
| `destination` | Instance Property |
| `errorDescription` | Instance Property |
| `skipped` | Instance Property |
| `source` | Instance Property |
| `warnings` | Instance Property |
| `MigrationReport` | Structure |
| `PiMigrator` | Structure |

## ZetaModes

| Symbol | Kind |
| --- | --- |
| `JSONLFramingError.recordTooLarge` | Case |
| `RPCCommandName.abort` | Case |
| `RPCCommandName.abortBash` | Case |
| `RPCCommandName.abortRetry` | Case |
| `RPCCommandName.bash` | Case |
| `RPCCommandName.clearQueue` | Case |
| `RPCCommandName.clone` | Case |
| `RPCCommandName.compact` | Case |
| `RPCCommandName.cycleModel` | Case |
| `RPCCommandName.cycleThinkingLevel` | Case |
| `RPCCommandName.exportHTML` | Case |
| `RPCCommandName.followUp` | Case |
| `RPCCommandName.fork` | Case |
| `RPCCommandName.getAvailableModels` | Case |
| `RPCCommandName.getAvailableThinkingLevels` | Case |
| `RPCCommandName.getCommands` | Case |
| `RPCCommandName.getEntries` | Case |
| `RPCCommandName.getForkMessages` | Case |
| `RPCCommandName.getLastAssistantText` | Case |
| `RPCCommandName.getMessages` | Case |
| `RPCCommandName.getSessionStats` | Case |
| `RPCCommandName.getState` | Case |
| `RPCCommandName.getTree` | Case |
| `RPCCommandName.newSession` | Case |
| `RPCCommandName.prompt` | Case |
| `RPCCommandName.setAutoCompaction` | Case |
| `RPCCommandName.setAutoRetry` | Case |
| `RPCCommandName.setFollowUpMode` | Case |
| `RPCCommandName.setModel` | Case |
| `RPCCommandName.setSessionName` | Case |
| `RPCCommandName.setSteeringMode` | Case |
| `RPCCommandName.setThinkingLevel` | Case |
| `RPCCommandName.steer` | Case |
| `RPCCommandName.switchSession` | Case |
| `RPCError.unknownCommand(_:)` | Case |
| `RPCProtocolError.invalidType` | Case |
| `RPCProtocolError.unknownCommand(_:)` | Case |
| `RPCUIRequest.confirm(id:title:message:)` | Case |
| `RPCUIRequest.editor(id:title:text:)` | Case |
| `RPCUIRequest.input(id:title:placeholder:)` | Case |
| `RPCUIRequest.notify(message:level:)` | Case |
| `RPCUIRequest.select(id:title:options:)` | Case |
| `RPCUIRequest.setEditorText(_:)` | Case |
| `RPCUIRequest.setStatus(key:value:)` | Case |
| `RPCUIRequest.setTitle(_:)` | Case |
| `RPCUIRequest.setWidget(key:lines:)` | Case |
| `RPCEngine` | Class |
| `JSONLFramingError` | Enumeration |
| `RPCCommandName` | Enumeration |
| `RPCError` | Enumeration |
| `RPCProtocolError` | Enumeration |
| `RPCUIRequest` | Enumeration |
| `serializeJSONLine(_:)` | Function |
| `init(from:)` | Initializer |
| `init(id:command:arguments:)` | Initializer |
| `init(id:command:fields:)` | Initializer |
| `init(id:command:success:data:error:)` | Initializer |
| `init(maximumRecordBytes:)` | Initializer |
| `init(rawValue:)` | Initializer |
| `init(write:)` | Initializer |
| `accept(_:)` | Instance Method |
| `encoded()` | Instance Method |
| `encodedLine()` | Instance Method |
| `finish()` | Instance Method |
| `push(_:)` | Instance Method |
| `register(_:handler:)` | Instance Method |
| `arguments` | Instance Property |
| `command` | Instance Property |
| `data` | Instance Property |
| `error` | Instance Property |
| `errorDescription` | Instance Property |
| `fields` | Instance Property |
| `id` | Instance Property |
| `maximumRecordBytes` | Instance Property |
| `success` | Instance Property |
| `type` | Instance Property |
| `LFJSONLDecoder` | Structure |
| `RPCRequest` | Structure |
| `RPCResponse` | Structure |
| `StrictRPCRequest` | Structure |
| `StrictRPCResponse` | Structure |
| `RPCEngine.Handler` | Type Alias |
| `decode(_:)` | Type Method |

## ZetaPackages

| Symbol | Kind |
| --- | --- |
| `PackageManagerError.invalidSource(_:)` | Case |
| `PackageManagerError.missingManifest` | Case |
| `PackageManagerError.processFailed(_:)` | Case |
| `PackageManagerError.unsafeArchive` | Case |
| `PackageManagerError.unsupportedExtensionPackage` | Case |
| `PackageManagerError.untrusted` | Case |
| `PackageSource.git(url:reference:)` | Case |
| `PackageSource.npm(name:version:)` | Case |
| `ResourcePackageManager` | Class |
| `PackageManagerError` | Enumeration |
| `PackageSource` | Enumeration |
| `init(_:)` | Initializer |
| `init(from:)` | Initializer |
| `init(root:session:)` | Initializer |
| `install(_:trusted:)` | Instance Method |
| `list()` | Instance Method |
| `remove(_:trusted:)` | Instance Method |
| `updateAll(trusted:)` | Instance Method |
| `directory` | Instance Property |
| `errorDescription` | Instance Property |
| `extensions` | Instance Property |
| `identifier` | Instance Property |
| `installedAt` | Instance Property |
| `name` | Instance Property |
| `pi` | Instance Property |
| `pinned` | Instance Property |
| `prompts` | Instance Property |
| `skills` | Instance Property |
| `source` | Instance Property |
| `themes` | Instance Property |
| `InstalledPackage` | Structure |
| `ResourcePackageManifest` | Structure |
| `ResourcePackageManifest.Resources` | Structure |

## ZetaPluginAPI

| Symbol | Kind |
| --- | --- |
| `PluginCapability.authentication` | Case |
| `PluginCapability.commands` | Case |
| `PluginCapability.events` | Case |
| `PluginCapability.flags` | Case |
| `PluginCapability.providers` | Case |
| `PluginCapability.resources` | Case |
| `PluginCapability.sessions` | Case |
| `PluginCapability.tools` | Case |
| `PluginCapability.userInterface` | Case |
| `PluginError.crashed(_:)` | Case |
| `PluginError.invalidManifest` | Case |
| `PluginError.malformedMessage` | Case |
| `PluginError.staleRuntime` | Case |
| `PluginError.timedOut` | Case |
| `PluginError.unsupportedCapability(_:)` | Case |
| `PluginError.unsupportedProtocol(_:)` | Case |
| `PluginError.untrusted` | Case |
| `PluginRegistration.Kind.authentication` | Case |
| `PluginRegistration.Kind.command` | Case |
| `PluginRegistration.Kind.event` | Case |
| `PluginRegistration.Kind.flag` | Case |
| `PluginRegistration.Kind.provider` | Case |
| `PluginRegistration.Kind.resource` | Case |
| `PluginRegistration.Kind.session` | Case |
| `PluginRegistration.Kind.tool` | Case |
| `PluginRegistration.Kind.ui` | Case |
| `PluginHost` | Class |
| `PluginCapability` | Enumeration |
| `PluginError` | Enumeration |
| `PluginRegistration.Kind` | Enumeration |
| `zetaPluginProtocolVersion` | Global Variable |
| `init()` | Initializer |
| `init(configuration:)` | Initializer |
| `init(from:)` | Initializer |
| `init(id:type:generation:method:payload:error:)` | Initializer |
| `init(kind:name:callback:schema:)` | Initializer |
| `init(name:version:protocolVersion:executable:capabilities:)` | Initializer |
| `init(rawValue:)` | Initializer |
| `currentRegistrations()` | Instance Method |
| `request(method:payload:)` | Instance Method |
| `start(manifest:baseDirectory:trusted:)` | Instance Method |
| `stop()` | Instance Method |
| `validate()` | Instance Method |
| `callback` | Instance Property |
| `capabilities` | Instance Property |
| `error` | Instance Property |
| `errorDescription` | Instance Property |
| `executable` | Instance Property |
| `generation` | Instance Property |
| `id` | Instance Property |
| `kind` | Instance Property |
| `maximumRecordBytes` | Instance Property |
| `method` | Instance Property |
| `name` | Instance Property |
| `payload` | Instance Property |
| `protocolVersion` | Instance Property |
| `requestTimeout` | Instance Property |
| `schema` | Instance Property |
| `type` | Instance Property |
| `version` | Instance Property |
| `PluginEnvelope` | Structure |
| `PluginHost.Configuration` | Structure |
| `PluginManifest` | Structure |
| `PluginRegistration` | Structure |
| `terminateActiveProcesses()` | Type Method |

## ZetaPluginSDK

| Symbol | Kind |
| --- | --- |
| `PluginSDKError.invalidEnvironment` | Case |
| `PluginSDKError.malformedEnvelope` | Case |
| `PluginSDKError.unknownCallback(_:)` | Case |
| `PluginSDK` | Enumeration |
| `PluginSDKError` | Enumeration |
| `init(id:handle:)` | Initializer |
| `init(registrations:callbacks:)` | Initializer |
| `callbacks` | Instance Property |
| `errorDescription` | Instance Property |
| `handle` | Instance Property |
| `id` | Instance Property |
| `registrations` | Instance Property |
| `PluginCallback` | Structure |
| `PluginDefinition` | Structure |
| `run(definition:input:output:environment:)` | Type Method |

## ZetaProtocol

| Symbol | Kind |
| --- | --- |
| `AssistantContent.text(_:)` | Case |
| `AssistantContent.thinking(_:)` | Case |
| `AssistantContent.toolCall(_:)` | Case |
| `AssistantDeltaKind.text` | Case |
| `AssistantDeltaKind.thinking` | Case |
| `AssistantDeltaKind.toolCall` | Case |
| `AssistantStopReason.length` | Case |
| `AssistantStopReason.stop` | Case |
| `AssistantStopReason.toolUse` | Case |
| `AssistantTranscriptState.aborted(message:)` | Case |
| `AssistantTranscriptState.complete(_:)` | Case |
| `AssistantTranscriptState.error(message:)` | Case |
| `AssistantTranscriptState.streaming` | Case |
| `CBORValue.array(_:)` | Case |
| `CBORValue.boolean(_:)` | Case |
| `CBORValue.byteString(_:)` | Case |
| `CBORValue.float(_:)` | Case |
| `CBORValue.integer(_:)` | Case |
| `CBORValue.map(_:)` | Case |
| `CBORValue.null` | Case |
| `CBORValue.textString(_:)` | Case |
| `ClientMessage.hello(_:)` | Case |
| `ClientMessage.request(_:)` | Case |
| `Command.abort(sessionID:)` | Case |
| `Command.attach(sessionID:)` | Case |
| `Command.create(_:)` | Case |
| `Command.detach(sessionID:)` | Case |
| `Command.list` | Case |
| `Command.prompt(sessionID:text:)` | Case |
| `Command.setModel(sessionID:model:)` | Case |
| `Command.setThinking(sessionID:thinkingLevel:)` | Case |
| `Command.steer(sessionID:text:)` | Case |
| `CommandName.abort` | Case |
| `CommandName.attach` | Case |
| `CommandName.create` | Case |
| `CommandName.detach` | Case |
| `CommandName.list` | Case |
| `CommandName.prompt` | Case |
| `CommandName.setModel` | Case |
| `CommandName.setThinking` | Case |
| `CommandName.steer` | Case |
| `CommandResult.abort(_:)` | Case |
| `CommandResult.attach(_:)` | Case |
| `CommandResult.create(_:)` | Case |
| `CommandResult.detach(sessionID:)` | Case |
| `CommandResult.list(_:)` | Case |
| `CommandResult.prompt(_:)` | Case |
| `CommandResult.setModel(_:)` | Case |
| `CommandResult.setThinking(_:)` | Case |
| `CommandResult.steer(_:)` | Case |
| `FinishedTranscriptItem.assistant(_:)` | Case |
| `FinishedTranscriptItem.tool(_:)` | Case |
| `ModelInput.image` | Case |
| `ModelInput.text` | Case |
| `ProtocolErrorCode.busy` | Case |
| `ProtocolErrorCode.internalError` | Case |
| `ProtocolErrorCode.invalidRequest` | Case |
| `ProtocolErrorCode.notFound` | Case |
| `ProtocolErrorCode.notImplemented` | Case |
| `ProtocolErrorCode.sessionLocked` | Case |
| `ProtocolErrorCode.version` | Case |
| `ProtocolModelError.invalid(_:)` | Case |
| `ResponseEnvelope.failure(id:error:)` | Case |
| `ResponseEnvelope.success(id:result:)` | Case |
| `ServerEvent.serverSnapshot(_:)` | Case |
| `ServerEvent.sessionProgress(sessionID:progress:)` | Case |
| `ServerEvent.sessionRemoved(sessionID:)` | Case |
| `ServerEvent.sessionSnapshot(_:)` | Case |
| `ServerMessage.event(_:)` | Case |
| `ServerMessage.hello(_:)` | Case |
| `ServerMessage.helloError(_:)` | Case |
| `ServerMessage.response(_:)` | Case |
| `SessionPhase.branchSummary` | Case |
| `SessionPhase.compaction` | Case |
| `SessionPhase.idle` | Case |
| `SessionPhase.retry` | Case |
| `SessionPhase.turn` | Case |
| `ThinkingLevel.high` | Case |
| `ThinkingLevel.low` | Case |
| `ThinkingLevel.max` | Case |
| `ThinkingLevel.medium` | Case |
| `ThinkingLevel.minimal` | Case |
| `ThinkingLevel.off` | Case |
| `ThinkingLevel.xhigh` | Case |
| `ToolContent.image(_:)` | Case |
| `ToolContent.text(_:)` | Case |
| `ToolTranscriptState.complete` | Case |
| `ToolTranscriptState.error` | Case |
| `ToolTranscriptState.running` | Case |
| `TranscriptItem.assistant(_:)` | Case |
| `TranscriptItem.tool(_:)` | Case |
| `TranscriptItem.user(_:)` | Case |
| `TranscriptProgress.assistantDelta(messageID:contentIndex:kind:delta:)` | Case |
| `TranscriptProgress.itemFinished(_:)` | Case |
| `TranscriptProgress.itemStarted(_:)` | Case |
| `TranscriptProgress.itemUpdated(_:)` | Case |
| `UpdatableTranscriptItem.assistant(_:)` | Case |
| `UpdatableTranscriptItem.tool(_:)` | Case |
| `UserContent.image(_:)` | Case |
| `UserContent.text(_:)` | Case |
| `ClientMessageDecoder` | Class |
| `ClientProtocolSequenceValidator` | Class |
| `FrameDecoder` | Class |
| `ServerMessageDecoder` | Class |
| `ServerProtocolSequenceValidator` | Class |
| `AssistantContent` | Enumeration |
| `AssistantDeltaKind` | Enumeration |
| `AssistantStopReason` | Enumeration |
| `AssistantTranscriptState` | Enumeration |
| `CBORCodec` | Enumeration |
| `CBORValue` | Enumeration |
| `ClientMessage` | Enumeration |
| `Command` | Enumeration |
| `CommandName` | Enumeration |
| `CommandResult` | Enumeration |
| `FinishedTranscriptItem` | Enumeration |
| `ModelInput` | Enumeration |
| `ProtocolErrorCode` | Enumeration |
| `ProtocolModelError` | Enumeration |
| `ResponseEnvelope` | Enumeration |
| `ServerEvent` | Enumeration |
| `ServerMessage` | Enumeration |
| `SessionPhase` | Enumeration |
| `ThinkingLevel` | Enumeration |
| `ToolContent` | Enumeration |
| `ToolTranscriptState` | Enumeration |
| `TranscriptItem` | Enumeration |
| `TranscriptProgress` | Enumeration |
| `UpdatableTranscriptItem` | Enumeration |
| `UserContent` | Enumeration |
| `assertCompleteFrame(_:options:)` | Function |
| `createClientMessageDecoder(options:)` | Function |
| `createServerMessageDecoder(options:)` | Function |
| `decodeCBOR(_:options:)` | Function |
| `decodeCbor(_:options:)` | Function |
| `encodeCBOR(_:options:)` | Function |
| `encodeCbor(_:options:)` | Function |
| `encodeClientMessage(_:options:)` | Function |
| `encodeFrame(_:)` | Function |
| `encodeServerMessage(_:options:)` | Function |
| `isSupportedProtocolVersion(_:)` | Function |
| `parseClientMessage(_:)` | Function |
| `parseServerMessage(_:)` | Function |
| `defaultMaximumCBORByteLength` | Global Variable |
| `defaultMaximumCBORContainerLength` | Global Variable |
| `defaultMaximumCBORDepth` | Global Variable |
| `defaultMaximumFrameLength` | Global Variable |
| `protocolVersion` | Global Variable |
| `init()` | Initializer |
| `init(_:)` | Initializer |
| `init(arrayLiteral:)` | Initializer |
| `init(assistant:)` | Initializer |
| `init(booleanLiteral:)` | Initializer |
| `init(code:message:details:)` | Initializer |
| `init(connectionID:snapshot:)` | Initializer |
| `init(cwd:name:model:thinkingLevel:)` | Initializer |
| `init(data:mimeType:)` | Initializer |
| `init(dictionaryLiteral:)` | Initializer |
| `init(floatLiteral:)` | Initializer |
| `init(from:)` | Initializer |
| `init(id:content:model:responseModel:usage:timestamp:state:)` | Initializer |
| `init(id:content:timestamp:)` | Initializer |
| `init(id:createdAt:updatedAt:parentSessionID:sessionName:cwd:)` | Initializer |
| `init(id:name:cwd:createdAt:updatedAt:phase:model:thinkingLevel:attached:locked:revision:transcript:queuedSteer:queuedSteerCount:)` | Initializer |
| `init(id:request:)` | Initializer |
| `init(id:toolCallID:toolName:input:content:details:usage:timestamp:state:)` | Initializer |
| `init(input:output:cacheRead:cacheWrite:)` | Initializer |
| `init(input:output:cacheRead:cacheWrite:reasoning:totalTokens:cost:)` | Initializer |
| `init(input:output:cacheRead:cacheWrite:total:)` | Initializer |
| `init(integerLiteral:)` | Initializer |
| `init(jsonValue:)` | Initializer |
| `init(key:value:)` | Initializer |
| `init(maxByteLength:maxContainerLength:maxDepth:)` | Initializer |
| `init(maxFrameLength:)` | Initializer |
| `init(maximumByteLength:maximumContainerLength:maximumDepth:)` | Initializer |
| `init(maximumFrameLength:)` | Initializer |
| `init(nilLiteral:)` | Initializer |
| `init(options:)` | Initializer |
| `init(provider:id:)` | Initializer |
| `init(provider:id:name:api:reasoning:input:contextWindow:maxTokens:cost:supportedThinkingLevels:authenticated:)` | Initializer |
| `init(rawValue:)` | Initializer |
| `init(serverID:revision:sessions:models:)` | Initializer |
| `init(stringLiteral:)` | Initializer |
| `init(text:)` | Initializer |
| `init(thinking:redacted:)` | Initializer |
| `init(tool:)` | Initializer |
| `init(toolCallID:toolName:input:)` | Initializer |
| `init(version:)` | Initializer |
| `accept(_:)` | Instance Method |
| `append(key:value:)` | Instance Method |
| `end()` | Instance Method |
| `index(after:)` | Instance Method |
| `index(before:)` | Instance Method |
| `jsonValue()` | Instance Method |
| `protocolJSONValue()` | Instance Method |
| `push(_:)` | Instance Method |
| `api` | Instance Property |
| `attached` | Instance Property |
| `authenticated` | Instance Property |
| `cacheRead` | Instance Property |
| `cacheWrite` | Instance Property |
| `code` | Instance Property |
| `connectionID` | Instance Property |
| `content` | Instance Property |
| `contextWindow` | Instance Property |
| `cost` | Instance Property |
| `createdAt` | Instance Property |
| `cwd` | Instance Property |
| `data` | Instance Property |
| `description` | Instance Property |
| `details` | Instance Property |
| `endIndex` | Instance Property |
| `entries` | Instance Property |
| `id` | Instance Property |
| `input` | Instance Property |
| `isTerminal` | Instance Property |
| `key` | Instance Property |
| `locked` | Instance Property |
| `maxFrameLength` | Instance Property |
| `maxTokens` | Instance Property |
| `maximumByteLength` | Instance Property |
| `maximumContainerLength` | Instance Property |
| `maximumDepth` | Instance Property |
| `maximumFrameLength` | Instance Property |
| `message` | Instance Property |
| `mimeType` | Instance Property |
| `model` | Instance Property |
| `models` | Instance Property |
| `name` | Instance Property |
| `output` | Instance Property |
| `parentSessionID` | Instance Property |
| `phase` | Instance Property |
| `provider` | Instance Property |
| `queuedSteer` | Instance Property |
| `queuedSteerCount` | Instance Property |
| `reasoning` | Instance Property |
| `redacted` | Instance Property |
| `request` | Instance Property |
| `responseModel` | Instance Property |
| `revision` | Instance Property |
| `serverID` | Instance Property |
| `sessionName` | Instance Property |
| `sessions` | Instance Property |
| `snapshot` | Instance Property |
| `startIndex` | Instance Property |
| `state` | Instance Property |
| `supportedThinkingLevels` | Instance Property |
| `text` | Instance Property |
| `thinking` | Instance Property |
| `thinkingLevel` | Instance Property |
| `timestamp` | Instance Property |
| `toolCallID` | Instance Property |
| `toolName` | Instance Property |
| `total` | Instance Property |
| `totalTokens` | Instance Property |
| `transcript` | Instance Property |
| `updatedAt` | Instance Property |
| `usage` | Instance Property |
| `value` | Instance Property |
| `version` | Instance Property |
| `subscript(_:)` | Instance Subscript |
| `ProtocolJSONConvertible` | Protocol |
| `AssistantTranscriptItem` | Structure |
| `CBORError` | Structure |
| `CBOROptions` | Structure |
| `ClientHello` | Structure |
| `CreateCommandOptions` | Structure |
| `FrameDecoderOptions` | Structure |
| `FrameError` | Structure |
| `ImageContent` | Structure |
| `ModelCost` | Structure |
| `ModelMetadata` | Structure |
| `ModelReference` | Structure |
| `OrderedCBORMap` | Structure |
| `OrderedCBORMap.Entry` | Structure |
| `ProtocolErrorValue` | Structure |
| `ProtocolValidationError` | Structure |
| `RequestEnvelope` | Structure |
| `ServerHello` | Structure |
| `ServerSnapshot` | Structure |
| `SessionMetadata` | Structure |
| `SessionSnapshot` | Structure |
| `TextContent` | Structure |
| `ThinkingContent` | Structure |
| `ToolCallContent` | Structure |
| `ToolTranscriptItem` | Structure |
| `Usage` | Structure |
| `UsageCost` | Structure |
| `UserTranscriptItem` | Structure |
| `ModelRef` | Type Alias |
| `OrderedCBORMap.Index` | Type Alias |
| `ProtocolError` | Type Alias |
| `decode(_:options:)` | Type Method |
| `encode(_:options:)` | Type Method |

## ZetaResources

| Symbol | Kind |
| --- | --- |
| `ResourceDiagnostic.Severity.error` | Case |
| `ResourceDiagnostic.Severity.warning` | Case |
| `ResourceError.missingDescription` | Case |
| `ResourceDiagnostic.Severity` | Enumeration |
| `ResourceError` | Enumeration |
| `init(home:workingDirectory:agentDirectory:trusted:)` | Initializer |
| `init(rawValue:)` | Initializer |
| `expand(arguments:)` | Instance Method |
| `load()` | Instance Method |
| `agentDirectory` | Instance Property |
| `body` | Instance Property |
| `context` | Instance Property |
| `description` | Instance Property |
| `diagnostics` | Instance Property |
| `directory` | Instance Property |
| `home` | Instance Property |
| `message` | Instance Property |
| `name` | Instance Property |
| `path` | Instance Property |
| `prompts` | Instance Property |
| `severity` | Instance Property |
| `skills` | Instance Property |
| `themes` | Instance Property |
| `trusted` | Instance Property |
| `unsupportedExtensions` | Instance Property |
| `workingDirectory` | Instance Property |
| `PromptTemplate` | Structure |
| `ResourceDiagnostic` | Structure |
| `ResourceLoader` | Structure |
| `ResourceSnapshot` | Structure |
| `Skill` | Structure |

## ZetaSearch

| Symbol | Kind |
| --- | --- |
| `SessionSearchError.duplicateSessionID(_:)` | Case |
| `SessionSearch` | Enumeration |
| `SessionSearchError` | Enumeration |
| `init(_:)` | Initializer |
| `init(entryTypes:limit:snippetCharacters:)` | Initializer |
| `init(sessionID:entryID:entryType:timestamp:text:label:)` | Initializer |
| `makeAsyncIterator()` | Instance Method |
| `next()` | Instance Method |
| `entryID` | Instance Property |
| `entryType` | Instance Property |
| `entryTypes` | Instance Property |
| `label` | Instance Property |
| `limit` | Instance Property |
| `sessionID` | Instance Property |
| `snippet` | Instance Property |
| `snippetCharacters` | Instance Property |
| `text` | Instance Property |
| `timestamp` | Instance Property |
| `ArraySearchSources` | Structure |
| `ArraySearchSources.AsyncIterator` | Structure |
| `SearchDocument` | Structure |
| `SessionSearchHit` | Structure |
| `SessionSearchOptions` | Structure |
| `ArraySearchSources.Element` | Type Alias |
| `jsonLineDocuments(sessionID:data:)` | Type Method |
| `scan(_:query:options:)` | Type Method |

## ZetaServer

| Symbol | Kind |
| --- | --- |
| `PiServerFailure.busy` | Case |
| `PiServerFailure.invalidRequest(_:)` | Case |
| `PiServerFailure.notFound` | Case |
| `PiServerFailure.notImplemented` | Case |
| `PiServer` | Class |
| `PiServerFailure` | Enumeration |
| `init(serverID:maximumFrameLength:handshakeTimeout:maximumPendingHandshakeRequests:maximumPendingHandshakeBytes:service:)` | Initializer |
| `init(serverID:maximumFrameLength:handshakeTimeout:service:)` | Initializer |
| `abort()` | Instance Method |
| `accept(_:)` | Instance Method |
| `close()` | Instance Method |
| `createSession(_:)` | Instance Method |
| `disconnected(_:)` | Instance Method |
| `dispose()` | Instance Method |
| `listModels()` | Instance Method |
| `listSessions()` | Instance Method |
| `openSession(_:)` | Instance Method |
| `prompt(_:)` | Instance Method |
| `receive(_:connectionID:)` | Instance Method |
| `send(_:)` | Instance Method |
| `setModel(_:)` | Instance Method |
| `setThinking(_:)` | Instance Method |
| `snapshot(attached:)` | Instance Method |
| `steer(_:)` | Instance Method |
| `id` | Instance Property |
| `serverID` | Instance Property |
| `PiServerService` | Protocol |
| `PiSessionRuntime` | Protocol |
| `ServerByteConnection` | Protocol |

## ZetaSessionFormat

| Symbol | Kind |
| --- | --- |
| `SessionFileFormat.codingAgent(version:)` | Case |
| `SessionFileFormat.harness(version:)` | Case |
| `SessionFileFormat.sqlite` | Case |
| `SessionFileFormat.unknown` | Case |
| `SessionFormatError.mismatch(expected:actual:)` | Case |
| `SessionFileFormat` | Enumeration |
| `SessionFormatDetector` | Enumeration |
| `SessionFormatError` | Enumeration |
| `errorDescription` | Instance Property |
| `detect(data:)` | Type Method |
| `detect(file:)` | Type Method |
| `require(_:data:)` | Type Method |

## ZetaSessionSQLite

| Symbol | Kind |
| --- | --- |
| `SQLiteForkScope.branch(entryID:includeTarget:)` | Case |
| `SQLiteForkScope.tree` | Case |
| `SQLiteRepositoryError.execute(_:)` | Case |
| `SQLiteRepositoryError.open(_:)` | Case |
| `SQLiteRepositoryError.staleLease` | Case |
| `SQLiteRepositoryError.unsupportedSQLite(_:)` | Case |
| `SQLiteRepositoryError.unsupportedSchema` | Case |
| `SQLiteSessionRepository` | Class |
| `SQLiteForkScope` | Enumeration |
| `SQLiteRepositoryError` | Enumeration |
| `init(from:)` | Initializer |
| `init(id:createdAt:cwd:parentSessionID:metadata:)` | Initializer |
| `init(url:leaseTTL:)` | Initializer |
| `acquireLease(sessionID:ownerID:now:)` | Instance Method |
| `append(sessionID:id:parentID:type:timestamp:payload:lease:now:)` | Instance Method |
| `appendRecord(sessionID:id:lane:runID:type:operationKind:timestamp:payload:lease:now:)` | Instance Method |
| `createLane(sessionID:lane:leafID:lease:now:)` | Instance Method |
| `createSession(_:)` | Instance Method |
| `deleteSession(_:)` | Instance Method |
| `entries(sessionID:)` | Instance Method |
| `forkSession(sourceID:destination:scope:)` | Instance Method |
| `initializeSearch()` | Instance Method |
| `integrityCheck()` | Instance Method |
| `label(sessionID:entryID:)` | Instance Method |
| `listSessions()` | Instance Method |
| `name(sessionID:)` | Instance Method |
| `records(sessionID:lane:type:)` | Instance Method |
| `renew(_:now:)` | Instance Method |
| `repairBranchCache(sessionID:)` | Instance Method |
| `search(_:limit:)` | Instance Method |
| `setLabel(sessionID:entryID:label:lease:now:)` | Instance Method |
| `setName(sessionID:name:lease:now:)` | Instance Method |
| `stats(sessionID:)` | Instance Method |
| `cachedTokens` | Instance Property |
| `costTotal` | Instance Property |
| `createdAt` | Instance Property |
| `cwd` | Instance Property |
| `errorDescription` | Instance Property |
| `expiresAtMilliseconds` | Instance Property |
| `fence` | Instance Property |
| `id` | Instance Property |
| `lane` | Instance Property |
| `leaseTTL` | Instance Property |
| `messageCount` | Instance Property |
| `metadata` | Instance Property |
| `operationKind` | Instance Property |
| `ownerID` | Instance Property |
| `parentID` | Instance Property |
| `parentSessionID` | Instance Property |
| `payload` | Instance Property |
| `runID` | Instance Property |
| `sequence` | Instance Property |
| `sessionID` | Instance Property |
| `timestamp` | Instance Property |
| `totalTokens` | Instance Property |
| `type` | Instance Property |
| `uncachedTokens` | Instance Property |
| `unownedExecutor` | Instance Property |
| `url` | Instance Property |
| `SQLiteEntry` | Structure |
| `SQLiteRecord` | Structure |
| `SQLiteSessionMetadata` | Structure |
| `SQLiteSessionStats` | Structure |
| `WriterLease` | Structure |

## ZetaSessions

| Symbol | Kind |
| --- | --- |
| `SessionEntry.branchSummary(_:fromID:summary:details:usage:fromHook:)` | Case |
| `SessionEntry.compaction(_:summary:firstKeptEntryID:tokensBefore:details:usage:fromHook:)` | Case |
| `SessionEntry.custom(_:customType:data:)` | Case |
| `SessionEntry.customMessage(_:customType:content:details:display:)` | Case |
| `SessionEntry.label(_:targetID:label:)` | Case |
| `SessionEntry.message(_:_:)` | Case |
| `SessionEntry.modelChange(_:provider:modelID:)` | Case |
| `SessionEntry.sessionInfo(_:name:)` | Case |
| `SessionEntry.thinkingLevelChange(_:_:)` | Case |
| `SessionError.duplicateID(_:)` | Case |
| `SessionError.invalidHeader` | Case |
| `SessionError.invalidSessionID` | Case |
| `SessionError.missingEntry(_:)` | Case |
| `SessionError.missingParent(_:)` | Case |
| `SessionError.unsupportedVersion(_:)` | Case |
| `SessionManager` | Class |
| `SessionTreeNode` | Class |
| `SessionEntry` | Enumeration |
| `SessionError` | Enumeration |
| `currentCodingSessionVersion` | Global Variable |
| `init()` | Initializer |
| `init(entry:)` | Initializer |
| `init(from:)` | Initializer |
| `init(header:entries:file:)` | Initializer |
| `init(id:parentId:timestamp:)` | Initializer |
| `init(version:id:timestamp:cwd:parentSession:)` | Initializer |
| `allEntries()` | Instance Method |
| `append(_:)` | Instance Method |
| `branch(to:)` | Instance Method |
| `clone(header:file:)` | Instance Method |
| `context(to:)` | Instance Method |
| `encode(to:)` | Instance Method |
| `finish()` | Instance Method |
| `fork(header:file:at:includeTarget:)` | Instance Method |
| `leaf()` | Instance Method |
| `materialize()` | Instance Method |
| `push(_:)` | Instance Method |
| `setLeaf(_:)` | Instance Method |
| `tree()` | Instance Method |
| `base` | Instance Property |
| `children` | Instance Property |
| `cwd` | Instance Property |
| `entry` | Instance Property |
| `errorDescription` | Instance Property |
| `file` | Instance Property |
| `header` | Instance Property |
| `id` | Instance Property |
| `messages` | Instance Property |
| `model` | Instance Property |
| `parentId` | Instance Property |
| `parentSession` | Instance Property |
| `thinkingLevel` | Instance Property |
| `timestamp` | Instance Property |
| `type` | Instance Property |
| `version` | Instance Property |
| `==(_:_:)` | Operator |
| `SessionContext` | Structure |
| `SessionEntryBase` | Structure |
| `SessionHeader` | Structure |
| `StrictJSONLDecoder` | Structure |
| `load(file:)` | Type Method |
| `validSessionID(_:)` | Type Method |

## ZetaTUI

| Symbol | Kind |
| --- | --- |
| `OverlayAnchor.bottomCenter` | Case |
| `OverlayAnchor.bottomLeft` | Case |
| `OverlayAnchor.bottomRight` | Case |
| `OverlayAnchor.center` | Case |
| `OverlayAnchor.leftCenter` | Case |
| `OverlayAnchor.rightCenter` | Case |
| `OverlayAnchor.topCenter` | Case |
| `OverlayAnchor.topLeft` | Case |
| `OverlayAnchor.topRight` | Case |
| `AltScreenTUI` | Class |
| `Box` | Class |
| `Container` | Class |
| `Editor` | Class |
| `HStack` | Class |
| `InlineImage` | Class |
| `Input` | Class |
| `Markdown` | Class |
| `OverlayHandle` | Class |
| `ScrollView` | Class |
| `SelectList` | Class |
| `SettingsList` | Class |
| `Spacer` | Class |
| `TUI` | Class |
| `Text` | Class |
| `TruncatedText` | Class |
| `VStack` | Class |
| `ANSI` | Enumeration |
| `ClipboardEscape` | Enumeration |
| `OverlayAnchor` | Enumeration |
| `cursorMarker` | Global Variable |
| `init()` | Initializer |
| `init(_:)` | Initializer |
| `init(_:basis:grow:minimumSize:)` | Initializer |
| `init(_:ellipsis:)` | Initializer |
| `init(_:horizontalPadding:verticalPadding:)` | Initializer |
| `init(_:spacing:)` | Initializer |
| `init(base64:mimeType:filename:maximumWidth:capabilities:)` | Initializer |
| `init(child:viewportHeight:followsEnd:)` | Initializer |
| `init(commands:baseDirectory:)` | Initializer |
| `init(id:label:description:currentValue:values:)` | Initializer |
| `init(items:)` | Initializer |
| `init(items:maximumVisible:)` | Initializer |
| `init(rawValue:)` | Initializer |
| `init(terminal:root:)` | Initializer |
| `init(terminal:root:transcriptOnExit:)` | Initializer |
| `init(value:label:description:)` | Initializer |
| `init(width:maximumHeight:anchor:offsetX:offsetY:margin:nonCapturing:)` | Initializer |
| `add(_:)` | Instance Method |
| `addInputListener(_:)` | Instance Method |
| `clear()` | Instance Method |
| `completions(for:)` | Instance Method |
| `handleInput(_:)` | Instance Method |
| `hasOverlay()` | Instance Method |
| `hide()` | Instance Method |
| `hideOverlay()` | Instance Method |
| `invalidate()` | Instance Method |
| `remove(_:)` | Instance Method |
| `render(width:)` | Instance Method |
| `requestRender(force:)` | Instance Method |
| `setFilter(_:)` | Instance Method |
| `setFocus(_:)` | Instance Method |
| `setHidden(_:)` | Instance Method |
| `setValue(_:)` | Instance Method |
| `showOverlay(_:options:)` | Instance Method |
| `start()` | Instance Method |
| `stop()` | Instance Method |
| `updateValue(id:value:)` | Instance Method |
| `value()` | Instance Method |
| `anchor` | Instance Property |
| `autocompleteProvider` | Instance Property |
| `base64` | Instance Property |
| `baseDirectory` | Instance Property |
| `basis` | Instance Property |
| `capabilities` | Instance Property |
| `child` | Instance Property |
| `children` | Instance Property |
| `commands` | Instance Property |
| `component` | Instance Property |
| `currentValue` | Instance Property |
| `description` | Instance Property |
| `disableSubmit` | Instance Property |
| `ellipsis` | Instance Property |
| `entries` | Instance Property |
| `filename` | Instance Property |
| `focused` | Instance Property |
| `followsEnd` | Instance Property |
| `grow` | Instance Property |
| `horizontalPadding` | Instance Property |
| `id` | Instance Property |
| `label` | Instance Property |
| `lines` | Instance Property |
| `margin` | Instance Property |
| `maximumHeight` | Instance Property |
| `maximumVisible` | Instance Property |
| `maximumVisibleLines` | Instance Property |
| `maximumWidth` | Instance Property |
| `mimeType` | Instance Property |
| `minimumSize` | Instance Property |
| `nonCapturing` | Instance Property |
| `offsetX` | Instance Property |
| `offsetY` | Instance Property |
| `onCancel` | Instance Property |
| `onChange` | Instance Property |
| `onSelect` | Instance Property |
| `onSelectionChange` | Instance Property |
| `onSubmit` | Instance Property |
| `source` | Instance Property |
| `spacing` | Instance Property |
| `value` | Instance Property |
| `values` | Instance Property |
| `verticalPadding` | Instance Property |
| `viewportHeight` | Instance Property |
| `width` | Instance Property |
| `AutocompleteProvider` | Protocol |
| `Component` | Protocol |
| `Focusable` | Protocol |
| `CombinedAutocompleteProvider` | Structure |
| `OverlayOptions` | Structure |
| `SelectItem` | Structure |
| `SettingItem` | Structure |
| `StackEntry` | Structure |
| `hyperlink(text:url:)` | Type Method |
| `osc52(_:)` | Type Method |
| `strip(_:)` | Type Method |
| `truncate(_:width:ellipsis:)` | Type Method |
| `visibleWidth(_:)` | Type Method |
| `wrap(_:width:)` | Type Method |

## ZetaTelemetry

| Symbol | Kind |
| --- | --- |
| `SpanStatus.error(_:)` | Case |
| `SpanStatus.ok` | Case |
| `TelemetryAttributeType.boolean` | Case |
| `TelemetryAttributeType.booleanArray` | Case |
| `TelemetryAttributeType.number` | Case |
| `TelemetryAttributeType.numberArray` | Case |
| `TelemetryAttributeType.string` | Case |
| `TelemetryAttributeType.stringArray` | Case |
| `TelemetryAttributeValue.boolean(_:)` | Case |
| `TelemetryAttributeValue.booleans(_:)` | Case |
| `TelemetryAttributeValue.number(_:)` | Case |
| `TelemetryAttributeValue.numbers(_:)` | Case |
| `TelemetryAttributeValue.string(_:)` | Case |
| `TelemetryAttributeValue.strings(_:)` | Case |
| `TelemetryCardinality.high` | Case |
| `TelemetryCardinality.low` | Case |
| `TelemetryParentDefinition.any` | Case |
| `TelemetryParentDefinition.rootOrExternal` | Case |
| `TelemetryParentDefinition.spans(_:)` | Case |
| `InMemoryTelemetryContext` | Class |
| `SpanStatus` | Enumeration |
| `TelemetryAdapterConformance` | Enumeration |
| `TelemetryAttributeType` | Enumeration |
| `TelemetryAttributeValue` | Enumeration |
| `TelemetryCardinality` | Enumeration |
| `TelemetryParentDefinition` | Enumeration |
| `TelemetrySchemaValidator` | Enumeration |
| `defineTelemetrySchema(_:)` | Function |
| `noopTelemetryContext` | Global Variable |
| `init()` | Initializer |
| `init(_:)` | Initializer |
| `init(arrayLiteral:)` | Initializer |
| `init(booleanLiteral:)` | Initializer |
| `init(context:getSpans:close:)` | Initializer |
| `init(description:attributes:)` | Initializer |
| `init(description:parents:startAttributes:endAttributes:events:errorWhen:)` | Initializer |
| `init(floatLiteral:)` | Initializer |
| `init(from:)` | Initializer |
| `init(group:name:body:)` | Initializer |
| `init(id:parentID:name:attributes:events:status:settled:endSequence:)` | Initializer |
| `init(integerLiteral:)` | Initializer |
| `init(name:attributes:)` | Initializer |
| `init(name:message:)` | Initializer |
| `init(rawValue:)` | Initializer |
| `init(stringLiteral:)` | Initializer |
| `init(type:description:required:sensitive:cardinality:allowedValues:examples:)` | Initializer |
| `init(version:spans:)` | Initializer |
| `accepts(_:)` | Instance Method |
| `addEvent(_:)` | Instance Method |
| `addEvent(_:attributes:)` | Instance Method |
| `encode(to:)` | Instance Method |
| `getSpans()` | Instance Method |
| `run()` | Instance Method |
| `setAttributes(_:)` | Instance Method |
| `setStatus(_:)` | Instance Method |
| `spans()` | Instance Method |
| `startSpan(_:operation:)` | Instance Method |
| `allowedValues` | Instance Property |
| `attributes` | Instance Property |
| `cardinality` | Instance Property |
| `close` | Instance Property |
| `context` | Instance Property |
| `description` | Instance Property |
| `endAttributes` | Instance Property |
| `endSequence` | Instance Property |
| `errorWhen` | Instance Property |
| `events` | Instance Property |
| `examples` | Instance Property |
| `getSpans` | Instance Property |
| `group` | Instance Property |
| `id` | Instance Property |
| `message` | Instance Property |
| `name` | Instance Property |
| `parentID` | Instance Property |
| `parentId` | Instance Property |
| `parents` | Instance Property |
| `required` | Instance Property |
| `sensitive` | Instance Property |
| `settled` | Instance Property |
| `spans` | Instance Property |
| `startAttributes` | Instance Property |
| `status` | Instance Property |
| `type` | Instance Property |
| `version` | Instance Property |
| `TelemetryContext` | Protocol |
| `TelemetrySpan` | Protocol |
| `NoOpTelemetryContext` | Structure |
| `RecordedTelemetryEvent` | Structure |
| `RecordedTelemetrySpan` | Structure |
| `SpanOptions` | Structure |
| `TelemetryAdapterConformanceCase` | Structure |
| `TelemetryAdapterFixture` | Structure |
| `TelemetryAttributeDefinition` | Structure |
| `TelemetryConformanceFailure` | Structure |
| `TelemetryErrorStatus` | Structure |
| `TelemetryEventDefinition` | Structure |
| `TelemetrySchemaDefinition` | Structure |
| `TelemetrySchemaError` | Structure |
| `TelemetrySpanDefinition` | Structure |
| `AttributeValue` | Type Alias |
| `SpanAttributes` | Type Alias |
| `TelemetryAdapterConformance.Factory` | Type Alias |
| `cases(factory:)` | Type Method |
| `validate(_:)` | Type Method |
| `validateAttributes(_:definitions:requireRequired:)` | Type Method |
| `shared` | Type Property |

## ZetaTerminal

| Symbol | Kind |
| --- | --- |
| `InlineImageProtocol.iterm` | Case |
| `InlineImageProtocol.kitty` | Case |
| `InlineImageProtocol.none` | Case |
| `ProcessTerminal` | Class |
| `VirtualTerminal` | Class |
| `InlineImageProtocol` | Enumeration |
| `init()` | Initializer |
| `init(columns:rows:)` | Initializer |
| `init(from:)` | Initializer |
| `init(hyperlinks:trueColor:imageProtocol:kittyKeyboard:synchronizedOutput:)` | Initializer |
| `init(input:output:)` | Initializer |
| `init(rawValue:)` | Initializer |
| `finish()` | Instance Method |
| `flushEscape()` | Instance Method |
| `push(_:)` | Instance Method |
| `send(_:)` | Instance Method |
| `start(onInput:onResize:)` | Instance Method |
| `stop()` | Instance Method |
| `write(_:)` | Instance Method |
| `columns` | Instance Property |
| `hasPendingEscape` | Instance Property |
| `hyperlinks` | Instance Property |
| `imageProtocol` | Instance Property |
| `kittyKeyboard` | Instance Property |
| `output` | Instance Property |
| `rows` | Instance Property |
| `synchronizedOutput` | Instance Property |
| `trueColor` | Instance Property |
| `writes` | Instance Property |
| `Terminal` | Protocol |
| `TerminalCapabilities` | Structure |
| `TerminalInputDecoder` | Structure |
| `detect(environment:)` | Type Method |
| `isKeyRelease(_:)` | Type Method |
| `restoreActiveTerminals()` | Type Method |

## ZetaTestSupport

| Symbol | Kind |
| --- | --- |
| `FailureInjector.Failure.injected(_:)` | Case |
| `DeterministicClock` | Class |
| `DeterministicIDs` | Class |
| `EffectGate` | Class |
| `FailureInjector` | Class |
| `LocalHTTPServer` | Class |
| `ScriptedSocket` | Class |
| `TemporaryDirectory` | Class |
| `ByteFragmenter` | Enumeration |
| `FailureInjector.Failure` | Enumeration |
| `init()` | Initializer |
| `init(failurePoints:)` | Initializer |
| `init(inbound:)` | Initializer |
| `init(milliseconds:)` | Initializer |
| `init(response:)` | Initializer |
| `init(start:)` | Initializer |
| `init(status:headers:body:)` | Initializer |
| `advance(by:)` | Instance Method |
| `append(_:)` | Instance Method |
| `capturedRequests()` | Instance Method |
| `next(prefix:)` | Instance Method |
| `now()` | Instance Method |
| `receive()` | Instance Method |
| `release(_:)` | Instance Method |
| `send(_:)` | Instance Method |
| `sent()` | Instance Method |
| `sleep(milliseconds:)` | Instance Method |
| `snapshot()` | Instance Method |
| `stop()` | Instance Method |
| `wait()` | Instance Method |
| `url` | Instance Property |
| `chunks(_:sizes:)` | Type Method |
| `everySplit(_:)` | Type Method |
| `serverSentEvents(_:)` | Type Method |

## ZetaTools

| Symbol | Kind |
| --- | --- |
| `FileToolError.aborted` | Case |
| `FileToolError.invalidEdit(_:)` | Case |
| `FileToolError.invalidPath(_:)` | Case |
| `FileToolError.multipleMatches(_:)` | Case |
| `FileToolError.noMatch(_:)` | Case |
| `FileToolError.overlappingEdits` | Case |
| `FileToolError.processFailed(_:)` | Case |
| `FileToolError.timedOut` | Case |
| `FileToolError.unreadable(_:)` | Case |
| `TruncationLimit.bytes` | Case |
| `TruncationLimit.lines` | Case |
| `FileMutationCoordinator` | Class |
| `FileToolError` | Enumeration |
| `Truncation` | Enumeration |
| `TruncationLimit` | Enumeration |
| `defaultMaximumBytes` | Global Variable |
| `defaultMaximumLines` | Global Variable |
| `grepMaximumLineLength` | Global Variable |
| `init(from:)` | Initializer |
| `init(oldText:newText:)` | Initializer |
| `init(rawValue:)` | Initializer |
| `init(workingDirectory:)` | Initializer |
| `init(workingDirectory:fileManager:)` | Initializer |
| `init(workingDirectory:shell:)` | Initializer |
| `edit(path:replacements:)` | Instance Method |
| `find(pattern:path:maximumResults:)` | Instance Method |
| `grep(pattern:path:filePattern:maximumMatches:)` | Instance Method |
| `list(path:limit:)` | Instance Method |
| `perform(at:operation:)` | Instance Method |
| `read(path:offset:limit:)` | Instance Method |
| `resolve(_:)` | Instance Method |
| `run(command:timeout:environment:onUpdate:)` | Instance Method |
| `write(path:content:)` | Instance Method |
| `content` | Instance Property |
| `errorDescription` | Instance Property |
| `exitCode` | Instance Property |
| `firstChangedLine` | Instance Property |
| `firstLineExceedsLimit` | Instance Property |
| `fullOutputFile` | Instance Property |
| `line` | Instance Property |
| `maximumBytes` | Instance Property |
| `maximumLines` | Instance Property |
| `newText` | Instance Property |
| `oldText` | Instance Property |
| `original` | Instance Property |
| `output` | Instance Property |
| `outputBytes` | Instance Property |
| `outputLines` | Instance Property |
| `partialBoundaryLine` | Instance Property |
| `path` | Instance Property |
| `replacements` | Instance Property |
| `shell` | Instance Property |
| `text` | Instance Property |
| `totalBytes` | Instance Property |
| `totalLines` | Instance Property |
| `truncated` | Instance Property |
| `truncatedBy` | Instance Property |
| `updated` | Instance Property |
| `workingDirectory` | Instance Property |
| `EditResult` | Structure |
| `FileTools` | Structure |
| `SearchMatch` | Structure |
| `SearchTools` | Structure |
| `ShellResult` | Structure |
| `ShellTool` | Structure |
| `TextReplacement` | Structure |
| `TruncationResult` | Structure |
| `format(bytes:)` | Type Method |
| `head(_:maximumLines:maximumBytes:)` | Type Method |
| `line(_:maximumCharacters:)` | Type Method |
| `tail(_:maximumLines:maximumBytes:)` | Type Method |
| `shared` | Type Property |

## ZetaUnixTransport

| Symbol | Kind |
| --- | --- |
| `UnixTransportError.closed` | Case |
| `UnixTransportError.invalidExistingPath` | Case |
| `UnixTransportError.pathTooLong(_:)` | Case |
| `UnixTransportError.pendingBytesExceeded` | Case |
| `UnixTransportError.system(_:_:)` | Case |
| `UnixByteTransport` | Class |
| `UnixServerConnection` | Class |
| `UnixServerListener` | Class |
| `UnixTransportError` | Enumeration |
| `createUnixTransportFactory(path:maximumPendingBytes:)` | Function |
| `init(path:maximumPendingBytes:handlers:)` | Initializer |
| `init(path:mode:onConnection:)` | Initializer |
| `close()` | Instance Method |
| `send(_:)` | Instance Method |
| `start(onData:onClose:)` | Instance Method |
| `errorDescription` | Instance Property |
| `id` | Instance Property |
| `path` | Instance Property |
