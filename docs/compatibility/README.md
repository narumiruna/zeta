# Compatibility artifacts

[Source baseline](source-baseline.md) defines the immutable Pi commit and product boundary.
[Baseline results](baseline-results.md) links to the actual disposable-checkout command record.
[Compatibility inventory](compatibility-inventory.json) maps generated source discoveries to Swift targets, acceptance tests, and audited outcomes.

Regenerate the inventory only from a clean checkout at the pinned commit.

```sh
uv run python scripts/generate-compatibility-inventory.py --source /path/to/pi
uv run python scripts/check-inventory.py --source /path/to/pi
```

Inventory extraction covers workspace manifests, manifest exports and bins, public TypeScript entry-point exports, deterministic test files, package documentation headings, CLI literals, environment names, settings interfaces, protocol schemas and literals, provider model families, built-in tools, TUI components, extension capabilities, and durable contracts.
The extraction intentionally over-inventories ambiguous flags and environment names rather than silently omitting a compatibility candidate.
Every required row must have `swiftTarget` and `acceptanceTest` values.
Every row must have an audited `implementationStatus` of `pass`, `intentional-difference`, or `non-goal`; `planned` is rejected by the inventory gate.

Fixture checks and regeneration are documented in [`Tests/CompatibilityFixtures/README.md`](../../Tests/CompatibilityFixtures/README.md).
