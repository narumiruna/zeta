#!/usr/bin/env -S uv run python
"""Validate fixture checksums and optionally reproduce the fixture set."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

COMMIT = "56700d42ed65a94a80af7376adb19a9298065164"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path)
    parser.add_argument("--root", type=Path, default=Path("Tests/CompatibilityFixtures"))
    args = parser.parse_args()
    manifest = json.loads((args.root / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("sourceCommit") != COMMIT:
        raise SystemExit("fixture source commit is not pinned")
    declared = set()
    for entry in manifest.get("files", []):
        path = args.root / entry["path"]
        declared.add(entry["path"])
        if not path.is_file():
            raise SystemExit(f"fixture is missing: {path}")
        data = path.read_bytes()
        if len(data) != entry["bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise SystemExit(f"fixture checksum mismatch: {path}")
    actual = {path.relative_to(args.root).as_posix() for path in (args.root / "v1").rglob("*") if path.is_file()}
    if actual != declared:
        raise SystemExit(f"fixture manifest coverage mismatch: undeclared={sorted(actual - declared)}, missing={sorted(declared - actual)}")
    if args.source:
        subprocess.run([
            "uv", "run", "python", str(args.root / "generate.py"), "--source", str(args.source),
            "--output", str(args.root), "--check",
        ], check=True)
    print(f"fixtures verified: {len(declared)} files at {COMMIT}")


if __name__ == "__main__":
    main()
