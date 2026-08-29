# ADR 0002: iOS library platform

- Status: Accepted
- Date: 2026-08-29
- Decision owners: Zeta maintainers

## Context

Zeta's executable product and pinned Pi compatibility contract target macOS.
Applications on iOS also need the portable AI provider and agent-loop libraries without the macOS command-line runtime.
Swift Package Manager declares deployment platforms for the package rather than for individual products.
Adding iOS at the package level can therefore make macOS-only products appear selectable even when they cannot compile for iOS.

## Decision

The package supports iOS 17 or newer for the `ZetaCore`, `ZetaTelemetry`, `ZetaAI`, and `ZetaAgent` module closure.
The supported consumer products are `ZetaAI` and `ZetaAgent`.
Consumers may add `ZetaCore` directly when tool implementations name its public JSON or schema types.
The iOS application owns its user interface, lifecycle, credential acquisition, sandbox access, and `AgentTool` effects.
Provider credentials must be injected explicitly instead of relying on process environment variables in a production iOS application.
A generic iPhoneOS build and focused external-consumer tests on an iOS Simulator are required CI checks.
The macOS 14 deployment target, executable products, compatibility formats, and release process remain unchanged.

## Supported boundary

| Capability | iOS status | Verification |
| --- | --- | --- |
| Ordered JSON and schema validation | Supported through `ZetaCore` | Generic iPhoneOS build and consumer tool test |
| Telemetry interfaces | Supported through `ZetaTelemetry` | Generic iPhoneOS build |
| Models, provider payloads, HTTP streaming, images, and WebSockets | Supported through `ZetaAI` | Generic iPhoneOS build and consumer catalog test |
| Agent loop, events, app-owned tools, retries, and cancellation | Supported through `ZetaAgent` | Generic iPhoneOS build and consumer agent test |
| CLI, terminal TUI, shell, child processes, executable plugins, package installation, and Unix transport | Not supported on iOS | Documented product boundary |
| Authentication helpers, Bedrock signing, sessions, SQLite, and migration | Outside the initial iOS contract | Documented product boundary |

## Security and lifecycle

Long-lived provider credentials embedded in a distributed application can be extracted.
Applications should prefer a backend or short-lived token flow and must not commit credentials to source.
Provider streams and agent runs may be suspended when iOS removes foreground execution time.
Zeta propagates cancellation, but the host application remains responsible for background execution policy and user-interface updates on `MainActor`.

## Consequences

The package manifest advertises iOS even though only the named module closure is supported there.
Documentation and CI must keep that narrower product contract explicit.
The external consumer fixture validates resource embedding and public imports without compiling unrelated macOS-only targets.
The supported iOS library closure does not link an external dependency or binary framework.
This decision extends the non-macOS portability consequence in [ADR 0001](0001-dependencies-and-macos-platform.md) only for the named iOS libraries.
