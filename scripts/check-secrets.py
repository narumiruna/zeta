#!/usr/bin/env -S uv run python
"""Scan tracked text for common credential material without printing values."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

PATTERNS = {
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "GitHub token": re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
    "AWS access key": re.compile(rb"\bAKIA[0-9A-Z]{16}\b"),
    "Slack token": re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    "assigned secret": re.compile(rb"(?i)(?:api[_-]?key|secret[_-]?key|auth[_-]?token)\s*[:=]\s*[\"'][A-Za-z0-9+/=_-]{24,}[\"']"),
}
ALLOW = {"Tests/CompatibilityFixtures/v1/migrations/auth-settings.json"}


def main() -> None:
    output = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard"], text=True)
    failures = []
    checked = 0
    for name in output.splitlines():
        if name in ALLOW:
            continue
        path = Path(name)
        if not path.is_file() or path.stat().st_size > 5_000_000:
            continue
        data = path.read_bytes()
        if b"\0" in data:
            continue
        checked += 1
        for label, pattern in PATTERNS.items():
            if pattern.search(data):
                failures.append(f"{name}: possible {label}")
    if failures:
        raise SystemExit("secret scan failed:\n" + "\n".join(failures))
    print(f"secret scan verified: {checked} text files")


if __name__ == "__main__":
    main()
