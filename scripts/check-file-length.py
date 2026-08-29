#!/usr/bin/env -S uv run python
"""Reject hand-written source or script files longer than 1,000 lines."""

from __future__ import annotations

import json
from pathlib import Path

LIMIT = 1000
SUFFIXES = {".swift", ".py", ".sh", ".md", ".yml", ".yaml"}


def main() -> None:
    generated = set(json.loads(Path(".generated-files.json").read_text(encoding="utf-8"))["paths"])
    failures = []
    checked = 0
    for path in sorted(Path(".").rglob("*")):
        relative = path.as_posix().removeprefix("./")
        if not path.is_file() or path.suffix not in SUFFIXES or any(part in {".git", ".build"} for part in path.parts):
            continue
        if relative in generated:
            continue
        checked += 1
        lines = sum(1 for _ in path.open("rb"))
        if lines > LIMIT:
            failures.append(f"{relative}: {lines}")
    if failures:
        raise SystemExit("files exceed 1,000 lines:\n" + "\n".join(failures))
    print(f"file length verified: {checked} hand-written files")


if __name__ == "__main__":
    main()
