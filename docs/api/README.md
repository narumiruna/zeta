# Swift API guide

Zeta is split into small SwiftPM libraries with explicit concurrency and format boundaries.
Every public symbol is listed in the generated [symbol reference](symbols.md).

## Core runtime

`ZetaCore` owns ordered JSON, strict parsing, JSON Schema validation, UUIDv7, timestamps, base64, and normalized errors.
`ZetaTelemetry` owns explicit callback spans, no-op and in-memory adapters, schema metadata, and conformance cases.
`ZetaAI` owns model and message values, streams, providers, catalogs, payload conversion, replay transforms, images, WebSockets, and dynamic refresh.
`ZetaAuth` owns API-key resolution, OAuth, PKCE, callback handling, refresh serialization, Vertex credential discovery, and AWS SigV4.
`ZetaBedrock` isolates AWS event-stream and Bedrock request behavior.
`ZetaAgent` owns agent state, event ordering, tools, queues, hooks, cancellation, and settlement.
On iOS 17 or newer, the supported closure is `ZetaCore`, `ZetaTelemetry`, `ZetaAI`, and `ZetaAgent`, with `ZetaAI` and `ZetaAgent` as the consumer products.
See the [iOS library guide](../user/ios-libraries.md) for the narrower platform boundary and compiling consumer example.
`ZetaCompaction` owns token estimation, cut points, summary prompts, and branch summaries.

## Durable data

`ZetaSessions` owns coding-agent JSONL version 3 and legacy migrations.
`ZetaHarnessSessions` owns current agent-core JSONL version 4 lanes, entries, records, and facts.
`ZetaSessionFormat` rejects format confusion before mutation.
`ZetaSessionSQLite` owns the pinned SQLite schema, leases, caches, facts, records, and FTS.
`ZetaSearch` provides portable asynchronous session scanning.
`ZetaMigration` provides backup-first import from Pi paths.

## Integration

`ZetaProtocol` owns strict protocol v1 CBOR and framing.
`ZetaClient` owns client connections and session leases.
`ZetaServer` owns concurrent server dispatch and runtime lifecycle.
`ZetaUnixTransport` owns macOS Unix sockets and filesystem publication.
`ZetaModes` owns strict JSONL and RPC records.
`ZetaExport` owns standalone HTML and JSONL export.

## User interface and extensibility

`ZetaTerminal` owns raw terminal lifecycle, capability detection, and input framing.
`ZetaTUI` owns renderers, components, editor behavior, layout, scrolling, and images.
`ZetaTools` owns filesystem, edit, search, shell, and truncation behavior.
`ZetaResources` owns context, prompts, skills, themes, and extension diagnostics.
`ZetaPackages` owns staged resource-package installation and updates.
`ZetaPluginAPI` owns the host protocol and process supervision.
`ZetaPluginSDK` owns plugin-side request handling and callback dispatch.
`ZetaCLI` composes the libraries into `zeta` and `pi`.
`ZetaEvals` provides deterministic seeded evaluation reports.

## Concurrency

Mutable shared state is actor-isolated unless a low-level framework requires a documented locked wrapper.
Provider, tool, socket, and plugin effects do not execute while holding unrelated actor state.
Cancellation is cooperative and is propagated through async provider, tool, OAuth, stream, and plugin operations.
Public stream failures are represented in terminal messages unless the API is a strict parser or setup operation.

## Examples

Create a model registry and install a provider before streaming.
Create an `Agent` with a stream closure and subscribe before prompting.
Use `SessionManager` for coding-agent JSONL and `HarnessSessionStorage` for current agent-core JSONL.
Use `PiClient` with a `ByteTransportFactory` or the Unix transport factory.
Use `PluginDefinition` and `PluginSDK.run` in a standalone Swift plugin executable.
The test targets contain deterministic examples for every library.
