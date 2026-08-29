# iOS libraries

Zeta supports iOS 17 or newer for the `ZetaAI` and `ZetaAgent` SwiftPM products.
Their supported transitive closure is `ZetaCore`, `ZetaTelemetry`, `ZetaAI`, and `ZetaAgent`.
An application may also select `ZetaCore` directly when its tools name `JSONValue` or `JSONSchema`.
This support is a library contract and does not port the `zeta` or `pi` executable to iOS.

## Add the products

Add this repository as a Swift package in Xcode, set the application deployment target to iOS 17 or newer, and select only `ZetaAI` and `ZetaAgent` for the application target.
Use a maintainer-approved immutable revision until the project publishes a supported release.
Do not select every product merely because SwiftPM advertises iOS at package level.

The independent [iOS consumer fixture](../../Examples/iOSLibraryConsumer/Package.swift) demonstrates the same product selection with a local checkout.

```swift
.package(name: "Zeta", path: "../..")
```

## Create an AI provider and agent

Import both public products in application code.
The compiling [consumer factory](../../Examples/iOSLibraryConsumer/Sources/ZetaIOSLibraryConsumer/IOSAgentFactory.swift) loads the bundled AI catalog, constructs an `HTTPProvider`, creates an app-owned `echo` tool, and injects the credential into each stream request.

```swift
import ZetaAI
import ZetaAgent

func startAgent(shortLivedCredential: String) async throws {
    let agent = try IOSAgentFactory.makeOpenAIAgent(
        apiKey: shortLivedCredential
    )
    try await agent.prompt(UserMessage("Summarize the selected text"))
}
```

`IOSAgentFactory` belongs to the example application rather than to Zeta.
Copy or adapt its implementation so the host application controls provider selection, credential acquisition, the system prompt, and tool effects.
The fixture's `FauxProvider` tests exercise the same AI stream and agent call shape without network access.

## Events and user-interface isolation

Subscribe before prompting when the application needs streaming updates.
`Agent` subscriber callbacks are asynchronous and are not guaranteed to run on the main actor.
Call a `@MainActor` view-model method or use `await MainActor.run` before mutating UIKit or SwiftUI state.
Unsubscribe when the owning screen or task is released.

## Credentials

Pass a credential explicitly through `StreamOptions.apiKey` or `StreamOptions.bearerToken`, as the consumer factory does.
Do not rely on process environment variables in a production iOS application.
A secret embedded in a distributed application can be extracted, so prefer a backend or provider-issued short-lived token with narrowly scoped access.
Never place a real credential in source, fixtures, application resources, analytics, or logs.

## Cancellation and lifecycle

Keep the `Task` that owns `agent.prompt` and cancel it when the user leaves the operation.
Also call `await agent.abort()` to settle the active provider stream and agent run promptly.
Application suspension can interrupt a stream at any point, and Zeta does not promise background completion.
The host application owns foreground and background execution policy.

## App-owned tools

Every `AgentTool` closure runs application-owned effects.
The application must enforce sandbox access, user consent, input validation, timeouts, and cancellation for those effects.
Zeta does not make the macOS filesystem, shell, process, terminal, package, or plugin tools available to iOS applications.

## Unsupported products

The following library products are outside the supported iOS contract: `ZetaAuth`, `ZetaBedrock`, `ZetaCompaction`, `ZetaExport`, `ZetaEvals`, `ZetaMigration`, `ZetaSessions`, `ZetaSearch`, `ZetaHarnessSessions`, `ZetaSessionFormat`, `ZetaSessionSQLite`, `ZetaProtocol`, `ZetaClient`, `ZetaServer`, `ZetaUnixTransport`, `ZetaConfig`, `ZetaResources`, `ZetaPackages`, `ZetaModes`, `ZetaTools`, `ZetaPluginAPI`, `ZetaPluginSDK`, `ZetaTerminal`, `ZetaTUI`, `ZetaTestSupport`, and `ZetaCLI`.
All executable products, including `zeta`, `pi`, benchmarks, and interoperability executables, are also unsupported on iOS.
`ZetaTelemetry` is supported as part of the transitive closure but is not an initial direct consumer product.
The package-level iOS declaration does not change these boundaries.
