# Contributing to Zeta

## Before starting

Read [AGENTS.md](AGENTS.md), the [source baseline](docs/compatibility/source-baseline.md), and the relevant compatibility documents.
Open an issue or design discussion before changing a durable format, protocol, plugin boundary, deployment target, or dependency policy.
Keep the Pi oracle at the pinned commit and clean.

## Development flow

Create a focused branch.
Make the smallest change that establishes the requested behavior.
Add deterministic tests or machine-checkable artifacts for every compatibility claim.
Do not depend on live provider credentials for required tests.
Record credential-gated skips with the missing credential or service name.
Update documentation in the same change when commands, formats, security boundaries, or generated artifacts change.

## Generated files

Files listed in `.generated-files.json` are generated.
Use the commands in [generated-file documentation](docs/development/generated-files.md).
Never repair a generated diff by hand.
A changed source baseline requires explicit approval and a coordinated fixture and inventory regeneration.

## Validation

Run the local gate from the repository root.

```sh
PI_SOURCE_ROOT=/path/to/pi scripts/check-repository.sh
```

Run focused tests for changed Swift modules after the package workspace exists.
Report exact commands, results, failures, skips, and environmental limitations in the pull request.
Do not hide flaky or unavailable checks by deleting tests or weakening assertions.

## Pull requests

Use a Conventional Commit pull request title.
Summarize the overall outcome rather than the sequence of edits.
Identify compatibility inventory rows affected by the change.
State whether fixture checksums changed and why.
Include dependency and license evidence when applicable.
Keep unrelated formatting and generated changes out of the diff.

## Commits

Use a Conventional Commit subject such as `docs(compatibility): record pinned baseline`.
Sign commits.
Stage intended paths explicitly rather than using blanket staging.
Do not include agent-attribution trailers unless a maintainer asks for them.
