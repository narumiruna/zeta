# Verification results

## Final local record

This historical baseline predates the dependencies accepted by [ADR 0003](../adr/0003-command-line-and-logging-dependencies.md).
These checks ran on 2026-08-28 on macOS arm64 with the Xcode Swift toolchain.
The pinned Pi oracle remained clean at `56700d42ed65a94a80af7376adb19a9298065164`.
No provider credential was present or printed.

| Check | Result |
| --- | --- |
| Compatibility inventory | 5,427 rows, 17 categories, zero unmapped required rows |
| Compatibility fixtures | 13 source-pinned files, byte-identical regeneration |
| Generated files | 18 declared generated artifacts |
| Documentation | 3,366 checked source lines before this final record update |
| File length | 176 hand-written files, all below 1,000 lines |
| Secret scan | 201 checked text files before this final record update |
| License audit | MIT project license and zero resolved external Swift dependencies |
| Strict arm64 build | Passed with complete concurrency and warnings as errors |
| arm64 tests | 96 XCTest plus 52 Swift Testing cases, zero failures and zero skips |
| x86_64 Rosetta build/tests | 96 XCTest plus 52 Swift Testing cases, zero failures and zero skips |
| AddressSanitizer | 96 XCTest plus 52 Swift Testing cases, no finding |
| ThreadSanitizer | 96 XCTest plus 52 Swift Testing cases, no finding |
| API documentation | 1,991 public symbols across 30 modules |
| Plugin examples | Independent release build passed |
| Interoperability | Protocol, both client/server directions, create/prompt/detach, sessions, TypeScript→Swift→TypeScript SQLite mutation, catalog, CLI, and RPC passed |
| Terminal signals | SIGTERM 143 and SIGHUP 129 restored termios, bracketed paste, and cursor state in pseudo-terminals |
| Release artifacts | arm64, x86_64, and universal binaries built; checksums, resources, symlink entry point, isolated install, faux-provider mode/RPC/interactive/plugin/session/export smoke passed |
| Reproducibility | Two independent arm64 archives for version 9.9.9 had identical SHA-256 |

The first repository commit has no prior `Package.swift`, so SwiftPM API breakage comparison correctly reports a one-time skip.
The generated public symbol inventory is the baseline for later changes.
Credential-gated live provider checks remain optional and are reported as unavailable rather than treated as deterministic failures.

## TypeScript oracle

The hydrated disposable oracle passed its complete offline deterministic suite.
Recorded source totals include 418 agent tests, 956 AI tests, 2,002 coding-agent tests, 147 protocol tests, 87 SQLite tests, 50 server tests, 36 client tests, 15 telemetry tests, 23 evaluation tests, the TUI runner, script tests, and browser smoke.
Credential-gated and external-service tests are explicit skips.
The detailed command and counts are in [`../compatibility/typescript-baseline-results.md`](../compatibility/typescript-baseline-results.md).

## Negative gates

A modified fixture checksum is rejected by `scripts/check-fixtures.py`.
A required inventory row without a target or acceptance test is rejected by `scripts/check-inventory.py`.
An extension-bearing resource package is rejected before publication.
A historical SQLite schema and wrong session formats are rejected without mutation.
A silent plugin times out and leaves no registrations.
A failed migration leaves the prior destination unchanged.
