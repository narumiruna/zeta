#!/bin/bash
set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" && -z "${ZETA_SWIFT_TOOLCHAIN_CONFIGURED:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

PYTHONDONTWRITEBYTECODE=1 uv run python -m unittest discover -s Tests/ScriptTests -p 'test_*.py'

source_root="${PI_SOURCE_ROOT:-}"
source_args=()
if [[ -n "$source_root" ]]; then
  source_args=(--source "$source_root")
fi

if [[ ${#source_args[@]} -gt 0 ]]; then
  uv run python scripts/check-inventory.py "${source_args[@]}"
  uv run python scripts/check-fixtures.py "${source_args[@]}"
else
  uv run python scripts/check-inventory.py
  uv run python scripts/check-fixtures.py
fi
uv run python scripts/check-generated-files.py
uv run python scripts/check-docs.py
uv run python scripts/check-file-length.py
uv run python scripts/check-secrets.py
uv run python scripts/check-licenses.py

scripts/check-swift-gates.sh
scripts/check-examples.sh
uv run python scripts/generate-api-docs.py --check
if [[ -n "${PI_ORACLE_ROOT:-}" || -d /tmp/zeta-pi-baseline-56700d42 ]]; then
  scripts/check-interop.sh
else
  echo "SKIP TypeScript interoperability: set PI_ORACLE_ROOT to a built pinned oracle checkout."
fi
