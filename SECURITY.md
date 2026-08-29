# Security policy

## Reporting

Report suspected vulnerabilities privately to the repository maintainers through GitHub private vulnerability reporting when it is enabled.
If private reporting is unavailable, contact a maintainer through a private channel listed on the repository profile.
Do not open a public issue containing exploit details, credentials, user prompts, session data, or provider responses.
Include affected commit, impact, reproduction steps, and a proposed mitigation when possible.
Maintainers will acknowledge the report, assess severity, and coordinate disclosure after a fix is available.

## Supported code

No Zeta release is currently supported because the Swift implementation and release gate are incomplete.
The pinned Pi source is a compatibility oracle and is not distributed or patched by this repository.
Security support policy will identify supported Zeta release lines before the first release.

## Trust boundaries

Provider credentials, Keychain entries, auth files, session files, project resources, plugins, package sources, tool processes, Unix sockets, and imported SQLite databases are security-sensitive inputs.
TypeScript extensions are unsupported and must never execute in Zeta.
Swift plugins will run out of process and require version, capability, and project-trust validation before host mutation.
Project resources must not execute merely because a repository was opened.
Package installation must disable lifecycle scripts.
Error messages and telemetry must redact credentials and sensitive provider payloads.

## Secrets and fixtures

Never commit real credentials or copied production configuration.
Use synthetic values containing an explicit `fixture` or `redacted` marker.
Run `uv run python scripts/check-secrets.py` before submission.
Secret scanning reduces risk but does not replace human review.
If a secret is committed, revoke it immediately and notify maintainers privately before rewriting history.

## Dependency and release safety

Follow [ADR 0001](docs/adr/0001-dependencies-and-macos-platform.md) for dependency review.
Pin package dependencies and CI actions to immutable revisions.
Release workflows in this repository are non-publishing skeletons until maintainers configure signing, notarization, protected environments, and release approval.
Never add publishing credentials to repository files or ordinary CI logs.
