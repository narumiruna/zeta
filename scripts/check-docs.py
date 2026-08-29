#!/usr/bin/env -S uv run python
"""Check required documentation, local Markdown links, and sentence-per-line style."""

from __future__ import annotations

import re
from pathlib import Path

REQUIRED = {
    "README.md", "AGENTS.md", "CONTRIBUTING.md", "SECURITY.md",
    "docs/compatibility/source-baseline.md", "docs/compatibility/typescript-baseline-results.md",
    "docs/compatibility/README.md", "docs/adr/0001-dependencies-and-macos-platform.md",
    "docs/adr/0003-command-line-and-logging-dependencies.md", "docs/development/README.md", "docs/development/testing.md", "docs/development/generated-files.md",
    "docs/development/release.md",
}
LINK = re.compile(r"(?<!!)\[[^]]+\]\(([^)]+)\)")


def main() -> None:
    missing = sorted(path for path in REQUIRED if not Path(path).is_file())
    if missing:
        raise SystemExit(f"required documents missing: {missing}")
    failures = []
    checked = 0
    for path in sorted([Path("README.md"), Path("AGENTS.md"), Path("CONTRIBUTING.md"), Path("SECURITY.md"), *Path("docs").rglob("*.md")]):
        in_fence = False
        for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.strip().startswith("```"):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            checked += 1
            sentence_ends = re.findall(r"[.!?](?:\s+|$)", line)
            if len(sentence_ends) > 1:
                failures.append(f"{path}:{line_no}: put each prose sentence on its own source line")
            for raw_target in LINK.findall(line):
                target = raw_target.split("#", 1)[0]
                if not target or "://" in target or target.startswith("mailto:"):
                    continue
                resolved = (path.parent / target).resolve()
                if not resolved.exists():
                    failures.append(f"{path}:{line_no}: broken local link {raw_target}")
    if failures:
        raise SystemExit("documentation check failed:\n" + "\n".join(failures))
    print(f"documentation verified: {checked} source lines")


if __name__ == "__main__":
    main()
