#!/usr/bin/env -S uv run python
"""Validate inventory completeness and optionally reproduce it from Pi."""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

REQUIRED_CATEGORIES = {
    "package-export", "cli-entry-point", "cli-flag", "cli-command", "environment-variable",
    "settings-field", "wire-schema", "durable-format", "provider-api-family", "built-in-tool",
    "tui-component", "extension-capability", "deterministic-test-file", "public-export",
    "documented-surface",
}
COMMIT = "56700d42ed65a94a80af7376adb19a9298065164"
ALLOWED_STATUSES = {"pass", "intentional-difference", "non-goal"}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path)
    parser.add_argument("--inventory", type=Path, default=Path("docs/compatibility/compatibility-inventory.json"))
    args = parser.parse_args()
    data = json.loads(args.inventory.read_text(encoding="utf-8"))
    if data.get("sourceCommit") != COMMIT:
        raise SystemExit("inventory source commit is not pinned")
    if data.get("schemaVersion") != 2:
        raise SystemExit("inventory schema version is stale")
    items = data.get("items", [])
    ids = [item.get("id") for item in items]
    if len(ids) != len(set(ids)):
        raise SystemExit("inventory IDs are not unique")
    categories = {item.get("category") for item in items}
    missing_categories = sorted(REQUIRED_CATEGORIES - categories)
    if missing_categories:
        raise SystemExit(f"inventory categories missing: {missing_categories}")
    unmapped = [item.get("id") for item in items if item.get("required") and (not item.get("swiftTarget") or not item.get("acceptanceTest"))]
    if unmapped:
        raise SystemExit(f"required rows are unmapped: {unmapped[:10]}")
    unfinished = [
        item.get("id") for item in items
        if item.get("implementationStatus") not in ALLOWED_STATUSES
    ]
    if unfinished:
        raise SystemExit(f"inventory rows are unfinished: {unfinished[:10]}")
    missing_acceptance = sorted({
        str(item.get("acceptanceTest")) for item in items
        if not Path(str(item.get("acceptanceTest"))).exists()
    })
    if missing_acceptance:
        raise SystemExit(f"inventory acceptance evidence is missing: {missing_acceptance[:10]}")
    if data.get("summary", {}).get("items") != len(items):
        raise SystemExit("inventory summary count is stale")
    if args.source:
        missing_evidence = []
        for item in items:
            evidence = str(item.get("evidence", ""))
            candidate, separator, suffix = evidence.rpartition(":")
            relative = candidate if separator and suffix.isdigit() else evidence
            if relative and not (args.source / relative).exists():
                missing_evidence.append(f"{item.get('id')}:{relative}")
        if missing_evidence:
            raise SystemExit(f"inventory evidence is missing from source: {missing_evidence[:10]}")
        with tempfile.TemporaryDirectory(prefix="zeta-inventory-") as temporary:
            generated = Path(temporary) / "inventory.json"
            subprocess.run([
                "uv", "run", "python", "scripts/generate-compatibility-inventory.py",
                "--source", str(args.source), "--output", str(generated),
            ], check=True)
            if generated.read_bytes() != args.inventory.read_bytes():
                raise SystemExit("inventory does not match a clean regeneration")
    print(f"inventory verified: {len(items)} rows, {len(categories)} categories, 0 unmapped required rows")


if __name__ == "__main__":
    main()
