# Generated files

`.generated-files.json` is the machine-readable ownership list for generated repository artifacts.
Generated compatibility inventory and fixture payloads must not be edited manually.
Generator programs and fixture documentation are hand-written and are not listed as generated.

## Compatibility inventory

```sh
uv run python scripts/generate-compatibility-inventory.py --source /path/to/pi
uv run python scripts/check-inventory.py --source /path/to/pi
```

The source checkout must be clean and exactly pinned.
The check generates a temporary copy and compares bytes.

## Compatibility fixtures

```sh
uv run python Tests/CompatibilityFixtures/generate.py --source /path/to/pi
uv run python scripts/check-fixtures.py --source /path/to/pi
```

The fixture manifest includes SHA-256 checksums and byte counts.
The fixture generator deletes only its output `v1` subtree and never writes to the Pi source.

## Review

Run `uv run python scripts/check-generated-files.py` after generation.
Inspect every changed checksum and inventory count.
A generator change and its regenerated outputs belong in the same pull request.
A source-commit change requires a baseline decision and is not a routine regeneration.
