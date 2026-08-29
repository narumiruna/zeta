#!/usr/bin/env -S uv run python
"""Require project licensing and an explicit review row for every resolved package."""

from __future__ import annotations

import json
import re
from pathlib import Path

LICENSE_REVIEW_PATH = Path("docs/adr/0003-command-line-and-logging-dependencies.md")
IDENTITY_ROW = re.compile(r"^\|\s*`([^`]+)`\s*\|")


def license_review_entries(adr: str) -> set[str]:
    lines = adr.splitlines()
    starts = [
        index + 1
        for index, line in enumerate(lines)
        if line.startswith("## License review")
    ]
    if len(starts) != 1:
        raise ValueError("dependency ADR must have one license review section")

    section = []
    for line in lines[starts[0] :]:
        if line.startswith("## "):
            break
        section.append(line)
    entries = [
        match.group(1).lower()
        for line in section
        if (match := IDENTITY_ROW.match(line))
    ]
    if len(entries) != len(set(entries)):
        raise ValueError("dependency ADR has duplicate identity rows in the license review")
    return set(entries)


def resolved_identities(path: Path) -> list[str]:
    if not path.exists():
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    pins = data.get("pins", data.get("object", {}).get("pins", []))
    if not isinstance(pins, list):
        raise ValueError("Package.resolved has no pin list")
    identities = []
    for index, pin in enumerate(pins):
        if not isinstance(pin, dict):
            raise ValueError(f"resolved pin {index} is invalid")
        identity = pin.get("identity") or pin.get("package")
        if not isinstance(identity, str) or not identity:
            raise ValueError(f"resolved pin {index} has no identity")
        identities.append(identity.lower())
    if len(identities) != len(set(identities)):
        raise ValueError("Package.resolved contains duplicate identities")
    return sorted(identities)


def check_license_review(root: Path) -> int:
    license_path = root / "LICENSE"
    adr_path = root / LICENSE_REVIEW_PATH
    if not license_path.is_file() or not license_path.read_text(encoding="utf-8").strip():
        raise ValueError("LICENSE is missing or empty")
    entries = license_review_entries(adr_path.read_text(encoding="utf-8"))
    packages = resolved_identities(root / "Package.resolved")
    missing = [name for name in packages if name not in entries]
    if missing:
        raise ValueError(f"resolved dependencies missing from license ADR: {missing}")
    return len(packages)


def main() -> None:
    try:
        count = check_license_review(Path.cwd())
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
    print(f"license review verified: project license plus {count} resolved dependencies")


if __name__ == "__main__":
    main()
