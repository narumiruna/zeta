# ADR 0001: Dependency policy and macOS platform

- Status: Draft; current command-line and logging selections are recorded in [ADR 0003](0003-command-line-and-logging-dependencies.md)
- Date: 2026-08-28
- Decision owners: Zeta maintainers

## Context

Zeta rewrites Pi behavior in Swift at source commit `56700d42ed65a94a80af7376adb19a9298065164`.
The first release supports macOS arm64 and x86_64 only.
The implementation requires strict JSON and CBOR, streaming HTTP and WebSockets, Unix sockets, SQLite FTS5, terminal Unicode, images, Markdown, resources, file locks, and deterministic tests.
Dependency choices affect cancellation, parsing, binary size, concurrency, compatibility, and supply-chain risk.

## Decision

The minimum deployment target is macOS 14.
External Swift packages are permitted when they provide a better capability, compatibility, correctness, maintenance, or security tradeoff than a platform API or focused implementation.
Packages maintained under [`apple`](https://github.com/apple) and [`swiftlang`](https://github.com/swiftlang) are explicitly permitted candidates when they help the project.
Their organization does not remove the requirement to review the selected package and its transitive dependencies.
The standard library and Apple SDK frameworks receive no automatic preference when an external package is the better engineering choice.
Dependency review must consider Pi compatibility, API fit, maintenance activity, known advisories, strict-concurrency behavior, supported platforms, build time, startup time, binary size, and direct and transitive licenses.
Direct dependencies must use an exact immutable release or revision, and the resolved transitive graph must be committed in `Package.resolved`.
Branch-based dependencies are not allowed.
A dependency must be attached only to the targets that use it.
A module protocol or adapter is required when it provides a useful replacement boundary, deterministic test seam, or compatibility boundary; it is not required by default.
A separate ADR is required only when a dependency materially changes an architectural, platform, security, durable-format, or compatibility decision.
Binary targets require checksums, provenance, all supported architectures, and explicit approval.

The current implementation uses Foundation for HTTP, SSE bytes, WebSocket tasks, files, JSON interoperability, dates, processes, and URL handling.
Network.framework provides the loopback OAuth callback listener.
CryptoKit provides SHA-256 and HMAC for PKCE and SigV4.
Darwin provides raw terminal state, process signals, Unix sockets, inode operations, and advisory file locks.
The macOS SQLite module provides WAL, FULL synchronization, FTS5 trigram search, UPSERT, `RETURNING`, triggers, and `WITHOUT ROWID`.
Focused Zeta modules currently implement ordered JSON, JSON Schema behavior, CBOR, ANSI width, Markdown terminal rendering, glob fallback, and plugin framing.
These are implementation selections rather than a prohibition on replacing them with reviewed packages.
XCTest and Swift Testing both run through SwiftPM because the pinned toolchain emits both test styles.

## Evidence

`Package.swift` currently resolves two external dependencies reviewed in [ADR 0003](0003-command-line-and-logging-dependencies.md).
`scripts/check-licenses.py` verifies the project license and requires every resolved dependency to appear in the current license review.
`scripts/check-repository.sh` verifies strict concurrency, warnings as errors, formatting, tests, generated files, fixtures, secrets, and API symbols.
The model catalog generator records its Pi source commit and SHA-256 checksum.
Protocol and terminal tests cover fragmentation, Unicode, malformed inputs, and restoration sequences.
SQLite tests cover required capabilities, writer fencing, branch caches, FTS, historical-schema rejection, and integrity.
macOS arm64 measurements are recorded under `docs/performance`.
The x86_64 build remains available as a local release-engineering path.

## Current selection matrix

| Capability | Selected implementation | Verification |
| --- | --- | --- |
| HTTP and SSE | `URLSession` plus `SSEDecoder` | Fragmentation, Unicode separator, error, cancellation, and payload tests |
| WebSocket | `URLSessionWebSocketTask` plus `CodexWebSocketPool` | Reuse, isolation, idle eviction, and failure disposal tests |
| Unix streams | Darwin sockets | Path, permissions, round-trip, replacement inode, and cleanup tests |
| SQLite and FTS5 | macOS `libsqlite3` | Schema, WAL, lease, cache, FTS, rollback, and integrity tests |
| OAuth callback | Network.framework | Loopback state and code validation test |
| Cryptography | CryptoKit | PKCE vector and deterministic SigV4 tests |
| YAML/frontmatter | Focused frontmatter parser | Resource validity and malformed-resource diagnostics |
| JSON Schema | `ZetaCore.JSONSchema` | Coercion, exact objects, unions, partial input, and randomized tests |
| Markdown | Focused terminal renderer | Heading, quote, list, width, and reset tests |
| Ignore and glob | `rg`, `fd`, and bounded fallback | Search, hidden path, result limit, and fallback tests |
| Image output | Terminal protocols and base64 validation | Kitty, iTerm, fallback, input, and output tests |
| Unicode width | Focused grapheme and East Asian ranges | CJK, emoji, combining mark, ANSI, and wrapping tests |
| File locking | Darwin `flock` | Atomic settings, auth, trust, and concurrent-process fixtures |
| Testing | XCTest plus Swift Testing | Async, parameterized, sanitizer, and CI execution |

## License review

The repository is MIT licensed.
The current external dependency license review is recorded in [ADR 0003](0003-command-line-and-logging-dependencies.md).
Apple SDK frameworks are platform components and are not vendored.
SQLite is public domain and is loaded from the macOS SDK.
Each external dependency must be added to the current license review with its identity, repository URL, exact release or revision, direct license, transitive packages and licenses, and advisory review.
A separate superseding ADR is not required for an ordinary dependency update.

## Consequences

Zeta does not enforce a zero-dependency architecture.
A reviewed package may reduce custom code and improve standards compliance, but it also adds supply-chain, build, binary-size, and maintenance costs.
Dependency decisions are made from measured project needs rather than a blanket preference for internal implementations.
Non-macOS portability is not a design requirement for the executable release.
[ADR 0002](0002-ios-library-platform.md) later extends support to the portable AI and agent library closure on iOS without changing the macOS executable contract.
Dependencies attached to the supported iOS library closure must also pass its device, simulator, and external-consumer checks.
Apple framework and package behavior is wrapped behind Zeta modules where deterministic substitution is useful.
arm64 CI is required, while x86_64 validation is an explicit local release check.
A universal binary is an optional packaging result and never substitutes for architecture-specific validation.
