# ADR 0003: Command-line parsing and logging dependencies

- Status: Accepted and implemented
- Date: 2026-08-29
- Decision owners: Zeta maintainers
- Related policy: [ADR 0001](0001-dependencies-and-macos-platform.md)

## Context

Zeta must preserve Pi command-line compatibility while rejecting malformed options predictably.
The hand-written parser duplicated established option parsing behavior and made future command growth harder to validate.
Zeta also needs structured diagnostic logging with levels and metadata that remains separate from user-facing output and telemetry.
Foundation does not provide a portable command-line parser or the server-oriented logging facade required by these capabilities.

## Decision

Zeta uses `apple/swift-argument-parser` 1.8.2 at revision `6a52f3251125d74daf04fcbd5e6f08a75d074382`.
The dependency is declared with an exact version requirement and is owned by `ZetaCLI`.
The private `CLIOptionParser` protocol isolates the `swift-argument-parser` adapter, and `CLIArguments` remains the public dependency-independent value boundary.
A small compatibility preprocessor preserves Pi-specific `--list-models`, `@file`, help, version, and `--` behavior before `ParsableArguments` performs option parsing.
The existing `CLIArguments` value remains the internal boundary used by session and runtime code.

Zeta uses `apple/swift-log` 1.9.1 at revision `2778fd4e5a12a8aaa30a3ee8285f4ce54c5f3181`.
The dependency is declared with an exact version requirement and is owned by `ZetaLogging`.
`ZetaLogSink` is the replaceable module protocol, and `ZetaLogger` is the dependency-independent facade used by product modules.
The default minimum level is `warning`, and `ZETA_LOG_LEVEL` can select `trace`, `debug`, `info`, `notice`, `warning`, `error`, or `critical`.
Logs use standard error and must never replace protocol output or telemetry spans.
Code must not include prompts, credentials, provider payloads, or file contents in log messages or metadata.

Neither dependency is part of the supported iOS `ZetaAI` and `ZetaAgent` library closure.

## License review and supply-chain pinning

| Identity | Repository | Exact release | Revision | License | Transitive packages |
| --- | --- | --- | --- | --- | --- |
| `swift-argument-parser` | `https://github.com/apple/swift-argument-parser.git` | 1.8.2 | `6a52f3251125d74daf04fcbd5e6f08a75d074382` | Apache-2.0 with Runtime Library Exception | None |
| `swift-log` | `https://github.com/apple/swift-log.git` | 1.9.1 | `2778fd4e5a12a8aaa30a3ee8285f4ce54c5f3181` | Apache-2.0 | None |

Both repositories are maintained by Apple under the Swift Server and Swift project organizations and publish versioned releases.
Their selected package manifests declare no external package dependencies.
GitHub's repository security-advisory endpoint returned zero published advisories for both repositories on 2026-08-29.
SwiftPM records both exact revisions in `Package.resolved`.
SwiftPM source-control dependencies do not provide binary artifact checksums, so the immutable Git revisions are the integrity pins.

## Concurrency and performance review

Both selected releases compile with Swift 6 complete strict concurrency and warnings as errors.
`ZetaLogging` exposes only `Sendable` values and sinks.
The logging facade does not introduce actor-isolated I/O.
Command-line parsing completes synchronously before long-running runtime effects begin.

Clean scratch builds used a warm SwiftPM repository cache and cold build directories on macOS arm64.
The x86_64 build used the explicit `x86_64-apple-macosx14.0` target triple, and the resulting executable architecture was verified with `file`.

| Build | Wall time | Result |
| --- | ---: | --- |
| arm64 strict debug build | 42.66 seconds | Passed |
| x86_64 strict debug build | 40.96 seconds | Passed |

The checked-out source sizes were approximately 2.5 MiB for `swift-argument-parser` and 640 KiB for `swift-log`.
No binary targets, plugins required by Zeta targets, or additional resolved packages were introduced.

## Consequences

The CLI delegates standard option parsing to a maintained Apple package while retaining a narrow compatibility adapter for Pi-specific syntax.
Logging has structured levels and metadata without coupling product modules directly to `swift-log`.
The resolved supply chain grows from zero to two source packages and must remain covered by the license and repository gates.
Future version changes require a new dependency review, exact pin updates, and both architecture builds.
