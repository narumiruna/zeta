# Toolchain

`.tool-versions` records Swift `6.2.0` and uv `0.9.26` for reproducible local setup.
`scripts/check-release-environment.sh` records actual tool versions and fails unless the PATH Swift compiler, selected Xcode Swift compiler, and uv match the pinned release toolchain.
Repository Python scripts use only the standard library and run through `uv run python`.
Swift formatting uses the `swift format` bundled with the pinned Swift toolchain.
API breakage uses `swift package diagnose-api-breaking-changes` against `ZETA_API_BASELINE` or the prior committed package baseline.
External formatter, linter, and vulnerability-scanner versions must not be added before dependency and license review.
The release environment gate requires a clean checkout and an arm64 host before architecture-specific validation.
