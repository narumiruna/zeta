# Zeta repository guide

## Scope

Zeta is a Swift-native macOS rewrite of Pi at commit `56700d42ed65a94a80af7376adb19a9298065164`.
Compatibility work must use a disposable clean source checkout.
Never edit `/Users/narumi/workspace/pi` or another designated source oracle.
Never infer compatibility from current upstream `main`.

## Design rules

Use KISS and YAGNI.
Keep hand-written source files below 1,000 lines.
Use Swift 6 strict concurrency for product code when the Swift workspace exists.
Long-running provider, process, storage, server, and plugin effects must execute outside actor isolation.
Use explicit discriminated decoding and reject unknown wire fields where the pinned contract is strict.
Preserve coding-agent JSONL v3, agent-core JSONL v4, protocol v1, and the current SQLite schema as separate contracts.
Do not embed Node.js or execute TypeScript extensions.
Swift plugins must use the versioned out-of-process boundary described by the plan.

## Documentation

Put each prose sentence on its own source line.
Use relative links for repository documents.
Do not mark rewrite-plan checkboxes without the coordinating maintainer.
Do not describe planned inventory rows or seed fixtures as passing implementation evidence.

## Generated artifacts

Do not hand-edit paths listed in `.generated-files.json`.
Regenerate inventory and fixtures from a clean pinned checkout.

```sh
uv run python scripts/generate-compatibility-inventory.py --source /path/to/pi
uv run python Tests/CompatibilityFixtures/generate.py --source /path/to/pi
```

Review the generated diff and run the owning checks.

## Checks

Run the repository gate from the repository root.

```sh
PI_SOURCE_ROOT=/path/to/pi scripts/check-repository.sh
```

Without `PI_SOURCE_ROOT`, the gate validates checked-in inventory and fixture checksums but does not reproduce source extraction.
When `Package.swift` exists, the gate also runs Swift package, build, test, warning, and strict-concurrency checks.
A checkout without `Package.swift` reports those Swift checks as explicit skips.

## Dependencies and security

Follow [ADR 0001](docs/adr/0001-dependencies-and-macos-platform.md) before adding a dependency.
Pin dependencies to immutable revisions.
Never commit credentials, tokens, private keys, provider responses containing user data, or production auth files.
Use synthetic redacted fixture values.
Do not publish, sign, notarize, or upload release assets from local validation commands.
Follow [SECURITY.md](SECURITY.md) for private vulnerability reports.

## Git

Preserve unrelated files and changes.
Stage only intended paths.
Use branch names in the form `narumi/<type>/<short-description>`.
Use Conventional Commit subjects.
Sign commits.
Do not add agent-attribution trailers unless explicitly requested.
