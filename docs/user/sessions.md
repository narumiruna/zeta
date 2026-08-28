# Sessions and migration

Zeta recognizes the coding-agent JSONL version 3 format and the separate agent-core JSONL version 4 format.
The two formats are detected explicitly and are never interpreted as each other.
Unknown future versions are rejected before mutation.

## Coding-agent sessions

Coding-agent sessions are append-only trees with entry IDs and parent IDs.
Version 1 and version 2 files are migrated in memory to version 3 semantics.
Malformed complete records are skipped for compatibility.
A valid final record without LF is repaired atomically.
A persistent file is delayed until an assistant response exists.
Branch, clone, fork, compaction, labels, names, model changes, and thinking changes preserve the selected tree path.

## Agent-core sessions

Agent-core sessions use a version 4 header and a shared sequence across entries, records, lane moves, and facts.
The current executable record-log format is implemented.
The future transaction/register harness design is intentionally not substituted for this format.
One operation may be open per lane.

## SQLite

Fresh SQLite databases use WAL, synchronous FULL, a five-second busy timeout, immediate write transactions, fenced writer leases, branch caches, and lazy FTS5 trigram search.
Historical databases that reused an older `001_initial.sql` shape are rejected without mutation.
Export those databases with their matching Pi version before migration.

## Migration

`PiMigrator` copies settings, credential metadata, sessions, skills, prompts, themes, resource packages, and supported databases after creating a backup.
Migration is idempotent for equal files.
TypeScript extensions are reported but not executed or translated automatically.
Never remove the source data until the migrated artifacts have been reopened and verified.
