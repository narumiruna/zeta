# Testing and engineering gates

## Repository gate

Run all currently available checks with a pinned clean Pi checkout.

```sh
PI_SOURCE_ROOT=/path/to/pi scripts/check-repository.sh
```

The gate checks inventory mappings, fixture checksums and reproducibility, generated declarations, documentation, file length, secrets, licenses, and focused repository-script regressions.
`scripts/check-swift-gates.sh` runs bundled Swift formatting, package validation, warning and strict-concurrency macOS builds, tests, and API breakage comparison when a package exists.
A checkout without `Package.swift` reports an explicit skip that is not a passing Swift result.

## Focused checks

Run the iOS 17 library boundary on a Mac with the iPhoneOS and iOS Simulator SDKs installed.
The gate selects any available iOS Simulator, fails if one is unavailable, and restores a simulator that it booted.

```sh
scripts/check-ios-libraries.sh
```

The iOS gate validates the manifest, warning and strict-concurrency builds for both supported products and SDKs, the external consumer build, and two synthetic simulator tests with zero allowed skips.
Its default diagnostics directory is `/tmp/zeta-ios-libraries` and CI overrides it with an uploaded artifact path.
The gate marks directories that it creates and refuses to clear an existing unmarked directory.

```sh
uv run python scripts/check-inventory.py --source /path/to/pi
uv run python scripts/check-fixtures.py --source /path/to/pi
uv run python scripts/check-generated-files.py
uv run python scripts/check-docs.py
uv run python scripts/check-file-length.py
uv run python scripts/check-secrets.py
uv run python scripts/check-package-dependencies.py
uv run python scripts/check-licenses.py
```

`check-inventory.py` requires all generated required rows to map to an owning Swift target and acceptance-test identifier.
`check-fixtures.py` verifies SHA-256 and byte size before optionally regenerating into a temporary directory.
`check-generated-files.py` verifies that generated artifacts are declared and runs their structural checks.
`check-docs.py` checks required files, local links, and the one-prose-sentence-per-source-line convention.
`check-file-length.py` enforces the 1,000-line limit outside declared generated artifacts.
`check-secrets.py` scans tracked and untracked repository text without printing candidate secret values.
`check-package-dependencies.py` permits only exact releases and revisions, verifies each direct origin and requirement against its pin, and compares the complete lock graph with an independent resolution.
`check-licenses.py` requires every `Package.resolved` identity to have a complete structured row matching its resolved repository, exact release, and revision in the current dependency ADR's License review section.

## Swift checks

After a package workspace exists, run package validation with warning and strict-concurrency enforcement.

```sh
swift package dump-package
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Formatting uses bundled `swift format` from the pinned toolchain.
API breakage uses `ZETA_API_BASELINE` when supplied and otherwise uses the previous committed package baseline when one exists.
Sanitizers and architecture-specific integration remain CI skeleton gates until compatible Swift tests exist.
Do not represent deferred sanitizer or architecture results as passing today.

## Baseline oracle

The exact TypeScript command record is in [TypeScript baseline results](../compatibility/typescript-baseline-results.md).
Required TypeScript checks must run in a disposable checkout.
Never hydrate mutable network data silently in a deterministic oracle run.
Retain structured test reports when the model catalog input is made reproducible.
