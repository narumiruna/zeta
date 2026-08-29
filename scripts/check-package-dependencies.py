#!/usr/bin/env -S uv run python
"""Enforce immutable Swift package requirements and a committed resolution graph."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any, NamedTuple


class DirectRequirement(NamedTuple):
    identity: str
    kind: str
    value: str


def load_manifest(path: Path | None) -> dict[str, Any]:
    if path is not None:
        return json.loads(path.read_text(encoding="utf-8"))
    result = subprocess.run(
        ["swift", "package", "dump-package"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def direct_requirements(manifest: dict[str, Any]) -> list[DirectRequirement]:
    dependencies = manifest.get("dependencies")
    if not isinstance(dependencies, list):
        raise ValueError("package manifest has no dependency list")

    requirements: list[DirectRequirement] = []
    for index, dependency in enumerate(dependencies):
        if not isinstance(dependency, dict) or len(dependency) != 1:
            raise ValueError(f"dependency {index} has an unsupported declaration")
        source_kind, records = next(iter(dependency.items()))
        if source_kind not in {"sourceControl", "registry"}:
            raise ValueError(
                f"dependency {index} uses unsupported {source_kind!r} requirement"
            )
        if not isinstance(records, list) or len(records) != 1:
            raise ValueError(f"dependency {index} has an invalid {source_kind} record")
        record = records[0]
        if not isinstance(record, dict):
            raise ValueError(f"dependency {index} has an invalid package record")
        identity = record.get("identity")
        requirement = record.get("requirement")
        if not isinstance(identity, str) or not identity:
            raise ValueError(f"dependency {index} has no identity")
        if not isinstance(requirement, dict) or len(requirement) != 1:
            raise ValueError(f"dependency {identity!r} has an invalid requirement")
        requirement_kind, values = next(iter(requirement.items()))
        if requirement_kind not in {"exact", "revision"}:
            raise ValueError(
                f"dependency {identity!r} must use an exact release or revision, "
                f"not {requirement_kind!r}"
            )
        if (
            not isinstance(values, list)
            or len(values) != 1
            or not isinstance(values[0], str)
            or not values[0]
        ):
            raise ValueError(f"dependency {identity!r} has an invalid requirement value")
        requirements.append(
            DirectRequirement(identity.lower(), requirement_kind, values[0])
        )

    identities = [requirement.identity for requirement in requirements]
    if len(identities) != len(set(identities)):
        raise ValueError("package manifest contains duplicate dependency identities")
    return requirements


def resolved_pins(path: Path) -> dict[str, dict[str, Any]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    pins = data.get("pins", data.get("object", {}).get("pins", []))
    if not isinstance(pins, list):
        raise ValueError("Package.resolved has no pin list")

    result: dict[str, dict[str, Any]] = {}
    for index, pin in enumerate(pins):
        if not isinstance(pin, dict):
            raise ValueError(f"resolved pin {index} is invalid")
        identity = pin.get("identity") or pin.get("package")
        state = pin.get("state")
        if not isinstance(identity, str) or not identity:
            raise ValueError(f"resolved pin {index} has no identity")
        if not isinstance(state, dict):
            raise ValueError(f"resolved pin {identity!r} has no state")
        normalized = identity.lower()
        if normalized in result:
            raise ValueError(f"Package.resolved contains duplicate identity {identity!r}")
        result[normalized] = state
    return result


def check_dependency_policy(manifest: dict[str, Any], resolved_path: Path) -> int:
    requirements = direct_requirements(manifest)
    if not requirements:
        return 0
    if not resolved_path.is_file():
        raise ValueError("external dependencies require a committed Package.resolved")

    pins = resolved_pins(resolved_path)
    for requirement in requirements:
        state = pins.get(requirement.identity)
        if state is None:
            raise ValueError(
                f"direct dependency {requirement.identity!r} is missing from Package.resolved"
            )
        state_key = "version" if requirement.kind == "exact" else "revision"
        if state.get(state_key) != requirement.value:
            raise ValueError(
                f"resolved {state_key} for {requirement.identity!r} does not match "
                f"the manifest requirement {requirement.value!r}"
            )
    return len(requirements)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--resolved", type=Path, default=Path("Package.resolved"))
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.manifest is None and not Path("Package.swift").is_file():
        print("SKIP package dependency policy: Package.swift is absent")
        return
    try:
        count = check_dependency_policy(load_manifest(args.manifest), args.resolved)
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"package dependency policy failed: {error}") from error
    print(f"package dependency policy verified: {count} direct dependencies")


if __name__ == "__main__":
    main()
