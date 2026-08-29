#!/usr/bin/env -S uv run python
"""Validate declarations and owning checks for generated repository artifacts."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path


def main() -> None:
    manifest = json.loads(Path(".generated-files.json").read_text(encoding="utf-8"))
    paths = manifest.get("paths", [])
    if len(paths) != len(set(paths)):
        raise SystemExit("generated file declarations contain duplicates")
    missing = [name for name in paths if not Path(name).is_file()]
    if missing:
        raise SystemExit(f"declared generated files are missing: {missing}")
    subprocess.run(["uv", "run", "python", "scripts/check-inventory.py"], check=True)
    subprocess.run(["uv", "run", "python", "scripts/check-fixtures.py"], check=True)
    print(f"generated files verified: {len(paths)} declared artifacts")


if __name__ == "__main__":
    main()
