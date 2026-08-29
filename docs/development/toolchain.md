# Toolchain

`.tool-versions` records Swift `6.2.0` and uv `0.9.26` for reproducible local setup.
Local validation must record actual tool versions and must not silently use an older Swift language toolchain.
Repository Python scripts use only the standard library and run through `uv run python`.
Swift formatting uses the `swift format` bundled with the pinned Swift toolchain.
API breakage uses `swift package diagnose-api-breaking-changes` against `ZETA_API_BASELINE` or the prior committed package baseline.
External formatter, linter, and vulnerability-scanner versions must not be added before dependency and license review.
Confirm the active architecture with `uname -m` before architecture-specific validation.
