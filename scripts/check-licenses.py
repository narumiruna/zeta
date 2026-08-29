#!/usr/bin/env -S uv run python
"""Require project licensing and a dependency license review for every resolved package."""

from __future__ import annotations

import json
from pathlib import Path


def main() -> None:
    license_path = Path("LICENSE")
    adr_path = Path("docs/adr/0003-command-line-and-logging-dependencies.md")
    if not license_path.is_file() or not license_path.read_text(encoding="utf-8").strip():
        raise SystemExit("LICENSE is missing or empty")
    adr = adr_path.read_text(encoding="utf-8")
    if "## License review" not in adr:
        raise SystemExit("dependency ADR has no license review")
    resolved = Path("Package.resolved")
    packages = []
    if resolved.exists():
        data = json.loads(resolved.read_text(encoding="utf-8"))
        pins = data.get("pins", data.get("object", {}).get("pins", []))
        packages = sorted(pin.get("identity") or pin.get("package") for pin in pins)
        missing = [name for name in packages if name and name.lower() not in adr.lower()]
        if missing:
            raise SystemExit(f"resolved dependencies missing from license ADR: {missing}")
    print(f"license review verified: project license plus {len(packages)} resolved dependencies")


if __name__ == "__main__":
    main()
