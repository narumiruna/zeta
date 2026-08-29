# ADR 0001: Dependency policy and macOS platform

- Status: Accepted and implemented
- Date: 2026-08-28
- Decision owners: Zeta maintainers

## Context

Zeta rewrites Pi behavior in Swift at source commit `56700d42ed65a94a80af7376adb19a9298065164`.
The first release supports macOS arm64 and x86_64 only.
The implementation requires strict JSON and CBOR, streaming HTTP and WebSockets, Unix sockets, SQLite FTS5, terminal Unicode, images, Markdown, resources, file locks, and deterministic tests.
Dependency choices affect cancellation, parsing, binary size, concurrency, compatibility, and supply-chain risk.

## Decision

The Swift package uses no external Swift package dependencies.
The minimum deployment target is macOS 14.
Foundation provides HTTP, SSE bytes, WebSocket tasks, files, JSON interoperability, dates, processes, and URL handling.
Network.framework provides the loopback OAuth callback listener.
CryptoKit provides SHA-256 and HMAC for PKCE and SigV4.
Darwin provides raw terminal state, process signals, Unix sockets, inode operations, and advisory file locks.
The macOS SQLite module provides WAL, FULL synchronization, FTS5 trigram search, UPSERT, `RETURNING`, triggers, and `WITHOUT ROWID`.
Focused Zeta modules implement ordered JSON, JSON Schema behavior, CBOR, ANSI width, Markdown terminal rendering, glob fallback, and plugin framing.
XCTest and Swift Testing both run through SwiftPM because the pinned toolchain emits both test styles.

External packages may be introduced only behind an owning module protocol and a new ADR.
Every future package must be pinned to an immutable release or revision and audited with its transitive licenses.
Binary targets require checksums, provenance, both architectures, and explicit approval.

## Evidence

`Package.swift` resolves zero external dependencies.
`scripts/check-licenses.py` verifies the project license and resolved dependency count.
`scripts/check-repository.sh` verifies strict concurrency, warnings as errors, formatting, tests, generated files, fixtures, secrets, and API symbols.
The model catalog generator records its Pi source commit and SHA-256 checksum.
Protocol and terminal tests cover fragmentation, Unicode, malformed inputs, and restoration sequences.
SQLite tests cover required capabilities, writer fencing, branch caches, FTS, historical-schema rejection, and integrity.
macOS arm64 measurements are recorded under `docs/performance`.
CI runs arm64 build, test, sanitizer, and release dry-run jobs.
The x86_64 build remains available as a local release-engineering path.

## Selection matrix

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
The Swift package resolves no external packages.
Apple SDK frameworks are platform components and are not vendored.
SQLite is public domain and is loaded from the macOS SDK.
Any future external dependency requires its exact license and transitive licenses in a superseding ADR.

## Consequences

Zeta has a small audited supply chain and a larger responsibility for focused compatibility code.
Non-macOS portability is not a design requirement for this release.
Apple framework behavior is wrapped behind Zeta modules where deterministic substitution is useful.
arm64 CI is required, while x86_64 validation is an explicit local release check.
A universal binary is an optional packaging result and never substitutes for architecture-specific validation.
