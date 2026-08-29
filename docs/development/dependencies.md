# Dependency updates

Read [ADR 0001](../adr/0001-dependencies-and-macos-platform.md) before proposing a package.
Document the required capability and explain why Foundation or a focused implementation is insufficient.
Benchmark the exact candidate revision on macOS arm64 and x86_64.
Record direct and transitive licenses, repository URL, revision, checksums where available, maintenance evidence, concurrency behavior, and known advisories.
Pin the selected dependency in `Package.resolved`.
Update the ADR license review so `uv run python scripts/check-licenses.py` can map every resolved identity.
Do not use branch-based dependencies or unaudited binary targets.
Keep the dependency behind its owning module protocol so it can be replaced without changing compatibility contracts.
