#!/usr/bin/env -S uv run python
"""Require project licensing and a structured review for every resolved package."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import NamedTuple

LICENSE_REVIEW_PATH = Path("docs/adr/0003-command-line-and-logging-dependencies.md")
REVIEW_COLUMNS = (
    "Identity",
    "Repository",
    "Exact release",
    "Revision",
    "License",
    "Transitive packages",
    "Advisory review",
)


class LicenseReviewEntry(NamedTuple):
    repository: str
    version: str
    revision: str
    license: str
    transitive_packages: str
    advisory_review: str


class ReviewedPin(NamedTuple):
    repository: str
    version: str
    revision: str


def markdown_cells(line: str) -> list[str] | None:
    stripped = line.strip()
    if not stripped.startswith("|") or not stripped.endswith("|"):
        return None
    return [cell.strip() for cell in stripped[1:-1].split("|")]


def cell_value(cell: str) -> str:
    if len(cell) >= 2 and cell.startswith("`") and cell.endswith("`"):
        return cell[1:-1].strip()
    return cell.strip()


def license_review_entries(adr: str) -> dict[str, LicenseReviewEntry]:
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

    headers = [
        index
        for index, line in enumerate(section)
        if markdown_cells(line) == list(REVIEW_COLUMNS)
    ]
    if len(headers) != 1:
        raise ValueError("dependency ADR must have one structured license review table")
    header = headers[0]
    if header + 1 >= len(section):
        raise ValueError("dependency ADR license review table has no separator")
    separator = markdown_cells(section[header + 1])
    if separator is None or len(separator) != len(REVIEW_COLUMNS) or any(
        re.fullmatch(r":?-{3,}:?", cell.replace(" ", "")) is None
        for cell in separator
    ):
        raise ValueError("dependency ADR license review table has an invalid separator")

    result: dict[str, LicenseReviewEntry] = {}
    for line in section[header + 2 :]:
        cells = markdown_cells(line)
        if cells is None:
            break
        if len(cells) != len(REVIEW_COLUMNS):
            raise ValueError("dependency ADR license review rows must have seven columns")
        values = [cell_value(cell) for cell in cells]
        identity = values[0].lower()
        if not identity:
            raise ValueError("dependency ADR license review row has no identity")
        if identity in result:
            raise ValueError(
                "dependency ADR has duplicate identity rows in the license review"
            )
        details = values[1:]
        if any(not value for value in details):
            raise ValueError(
                f"dependency ADR license review row for {identity!r} has empty fields"
            )
        result[identity] = LicenseReviewEntry(*details)
    return result


def resolved_pins(path: Path) -> dict[str, ReviewedPin]:
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    pins = data.get("pins", data.get("object", {}).get("pins", []))
    if not isinstance(pins, list):
        raise ValueError("Package.resolved has no pin list")

    result: dict[str, ReviewedPin] = {}
    for index, pin in enumerate(pins):
        if not isinstance(pin, dict):
            raise ValueError(f"resolved pin {index} is invalid")
        identity = pin.get("identity") or pin.get("package")
        repository = pin.get("location") or pin.get("repositoryURL")
        state = pin.get("state")
        if not isinstance(identity, str) or not identity:
            raise ValueError(f"resolved pin {index} has no identity")
        if not isinstance(repository, str) or not repository:
            raise ValueError(f"resolved pin {identity!r} has no repository location")
        if not isinstance(state, dict):
            raise ValueError(f"resolved pin {identity!r} has no state")
        version = state.get("version", "N/A")
        revision = state.get("revision", "N/A")
        if not isinstance(version, str) or not version:
            raise ValueError(f"resolved pin {identity!r} has an invalid version")
        if not isinstance(revision, str) or not revision:
            raise ValueError(f"resolved pin {identity!r} has an invalid revision")
        normalized = identity.lower()
        if normalized in result:
            raise ValueError("Package.resolved contains duplicate identities")
        result[normalized] = ReviewedPin(repository, version, revision)
    return result


def check_license_review(root: Path) -> int:
    license_path = root / "LICENSE"
    adr_path = root / LICENSE_REVIEW_PATH
    if not license_path.is_file() or not license_path.read_text(encoding="utf-8").strip():
        raise ValueError("LICENSE is missing or empty")

    entries = license_review_entries(adr_path.read_text(encoding="utf-8"))
    pins = resolved_pins(root / "Package.resolved")
    missing = sorted(pins.keys() - entries.keys())
    unexpected = sorted(entries.keys() - pins.keys())
    if missing:
        raise ValueError(f"resolved dependencies missing from license ADR: {missing}")
    if unexpected:
        raise ValueError(f"license ADR contains unresolved dependencies: {unexpected}")

    for identity, pin in pins.items():
        entry = entries[identity]
        if entry.repository != pin.repository:
            raise ValueError(
                f"license ADR repository for {identity!r} does not match Package.resolved"
            )
        if entry.version != pin.version:
            raise ValueError(
                f"license ADR exact release for {identity!r} does not match Package.resolved"
            )
        if entry.revision != pin.revision:
            raise ValueError(
                f"license ADR revision for {identity!r} does not match Package.resolved"
            )
    return len(pins)


def main() -> None:
    try:
        count = check_license_review(Path.cwd())
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
    print(f"license review verified: project license plus {count} resolved dependencies")


if __name__ == "__main__":
    main()
