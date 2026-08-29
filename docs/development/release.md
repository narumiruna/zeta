# Release engineering

Zeta release artifacts are produced locally and in a manual non-publishing workflow.
The workflow must not create a GitHub release, push tags, upload to a package registry, use production signing identities, or submit notarization requests.
Publishing requires a separate reviewed change.

## Local dry run

Run the repository gate first.

```sh
PI_SOURCE_ROOT=/path/to/pinned/pi scripts/check-repository.sh
```

Build architecture-specific artifacts.

```sh
scripts/build-release.sh --arch arm64 --out /tmp/zeta-arm64
arch -x86_64 scripts/build-release.sh --arch x86_64 --out /tmp/zeta-x86_64
scripts/build-universal.sh /tmp/zeta-universal
scripts/check-release-smoke.sh /tmp/zeta-universal
scripts/build-source-archive.sh /tmp/zeta-source.tar.gz
```

Each artifact contains the `zeta` executable, a `pi` symlink to the same executable, the model-catalog resource bundle, documentation, license, embedded version, and checksums.
Archive ordering, metadata timestamps, and gzip headers are normalized so repeated builds from identical inputs match.
Verify checksums before installation.

```sh
(cd /tmp/zeta-arm64 && shasum -a 256 -c SHA256SUMS)
PREFIX=/tmp/zeta-install scripts/install.sh /tmp/zeta-arm64
/tmp/zeta-install/bin/zeta --help
/tmp/zeta-install/bin/pi --version
PREFIX=/tmp/zeta-install scripts/uninstall.sh
```

`ZETA_CODESIGN_IDENTITY` enables the optional hardened-runtime signing hook.
`scripts/notarize.sh` requires an explicit artifact and keychain profile and only submits when invoked directly.
Unsigned local and CI dry runs are expected.

## CI

`.github/workflows/ci.yml` runs repository gates and an arm64 strict build, tests, sanitizers, and retained reports.
`.github/workflows/release-dry-run.yml` creates and installs an unsigned arm64 artifact without publishing it.
The x86_64 path remains available for explicit local release validation.

## Publishing activation

Before publishing is enabled, maintainers must review both architecture reports, compatibility outcomes, versioning, signing, notarization, protected environments, approvals, rollback, source archives, dependency provenance, licenses, checksums, vulnerability reports, and installation evidence.
Publishing activation must never be hidden in a workflow refactor.
