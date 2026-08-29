# Dependency updates

Read [ADR 0001](../adr/0001-dependencies-and-macos-platform.md) and [ADR 0003](../adr/0003-command-line-and-logging-dependencies.md) before adding a package.
Packages from [`apple`](https://github.com/apple) and [`swiftlang`](https://github.com/swiftlang) are permitted candidates when they help the project.
Apply the same package-specific and transitive review to these organizations as to any other source.
Document the required capability and compare the package with plausible platform APIs, focused implementations, and existing dependency boundaries.
Evaluate compatibility, API fit, maintenance, security, strict concurrency, supported platforms, build time, startup time, and binary size.
Benchmark the exact candidate revision on every release architecture affected by the dependency.
Record direct and transitive licenses, repository URL, exact release or revision, checksums where available, maintenance evidence, concurrency behavior, and known advisories.
Pin each direct dependency to an exact immutable release or revision and commit `Package.resolved`.
Update the current dependency license review so `uv run python scripts/check-licenses.py` can map every resolved identity.
Do not use branch-based dependencies or unaudited binary targets.
Attach the dependency only to targets that use it.
Add a protocol or adapter when replacement, deterministic testing, or compatibility isolation requires one.
Use a separate ADR only when the dependency changes an architectural, platform, security, durable-format, or compatibility decision.
