# Compatibility fixtures

This directory contains deterministic source-pinned golden vectors for every compatibility fixture family.
The families cover canonical JSON, event JSONL, RPC, provider requests and streams, CBOR and framing, both session formats, SQLite, ANSI rendering, auth and settings migration, and tool results.

`manifest.json` records the pinned source commit, source tree, generator command, byte count, and SHA-256 checksum for every generated file.
The generator refuses a dirty or differently pinned source checkout.

```sh
uv run python Tests/CompatibilityFixtures/generate.py --source /path/to/pi
uv run python scripts/check-fixtures.py --source /path/to/pi
```

The check regenerates into a temporary directory and requires byte-identical output.
The SQLite fixture is built with deterministic schema and insertion order before `VACUUM`.

Swift compatibility tests consume every fixture family directly.
The interoperability gate opens durable artifacts and wire vectors with the pinned TypeScript oracle and Swift implementation.
Synthetic credentials are redacted placeholders and are not usable secrets.
