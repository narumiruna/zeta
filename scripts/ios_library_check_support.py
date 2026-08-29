#!/usr/bin/env python3
"""Safe filesystem and simulator selection helpers for the iOS library gate."""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

ARTIFACT_MARKER = ".zeta-ios-libraries-artifacts"
ARTIFACT_MARKER_CONTENT = "zeta-ios-libraries-v1\n"
RUNTIME_PREFIX = "com.apple.CoreSimulator.SimRuntime.iOS-"


def prepare_artifacts_directory(raw_path: str, repository_root: str) -> Path:
    path = Path(raw_path).expanduser().resolve(strict=False)
    root = Path(repository_root).resolve()
    if path == Path("/") or path == root:
        raise ValueError(f"refusing unsafe iOS artifacts directory: {path}")

    existed = path.exists() or path.is_symlink()
    marker = path / ARTIFACT_MARKER
    if existed:
        if not path.is_dir():
            raise ValueError(f"iOS artifacts path is not a directory: {path}")
        if (
            marker.is_symlink()
            or not marker.is_file()
            or marker.read_text(encoding="utf-8") != ARTIFACT_MARKER_CONTENT
        ):
            raise ValueError(
                f"refusing existing iOS artifacts directory not owned by this script: {path}"
            )
    else:
        path.mkdir(parents=True)
        marker.write_text(ARTIFACT_MARKER_CONTENT, encoding="utf-8")

    for child in path.iterdir():
        if child.name == ARTIFACT_MARKER:
            continue
        if child.is_symlink() or not child.is_dir():
            child.unlink()
        else:
            shutil.rmtree(child)
    return path


def parse_runtime_version(runtime: str) -> tuple[int, int, int] | None:
    if not runtime.startswith(RUNTIME_PREFIX):
        return None
    try:
        parts = [int(part) for part in runtime.removeprefix(RUNTIME_PREFIX).split("-")]
    except ValueError:
        return None
    if not 1 <= len(parts) <= 3:
        return None
    return tuple((parts + [0, 0, 0])[:3])


def select_simulator(
    payload: dict[str, object],
    minimum_version: tuple[int, int, int] = (17, 0, 0),
) -> tuple[str, str, str]:
    candidates: list[tuple[bool, tuple[int, int, int], str, str, str]] = []
    devices_by_runtime = payload.get("devices", {})
    if not isinstance(devices_by_runtime, dict):
        raise ValueError("simulator inventory does not contain a devices object")
    for runtime, raw_devices in devices_by_runtime.items():
        version = parse_runtime_version(runtime)
        if version is None or version < minimum_version or not isinstance(raw_devices, list):
            continue
        for device in raw_devices:
            if not isinstance(device, dict):
                continue
            state = device.get("state")
            udid = device.get("udid")
            name = device.get("name")
            if state in {"Booted", "Shutdown"} and isinstance(udid, str) and isinstance(name, str):
                candidates.append((state != "Booted", version, udid, state, name))
    if not candidates:
        minimum = ".".join(str(value) for value in minimum_version[:2])
        raise ValueError(f"no available iOS {minimum}-or-newer Simulator is installed")
    _, _, udid, state, name = sorted(candidates)[0]
    return udid, state, name


def parse_minimum_version(value: str) -> tuple[int, int, int]:
    try:
        parts = [int(part) for part in value.split(".")]
    except ValueError as error:
        raise argparse.ArgumentTypeError("minimum version must contain integers") from error
    if not 1 <= len(parts) <= 3:
        raise argparse.ArgumentTypeError("minimum version must have one to three components")
    return tuple((parts + [0, 0, 0])[:3])


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare = subparsers.add_parser("prepare-artifacts")
    prepare.add_argument("path")
    prepare.add_argument("repository_root")
    select = subparsers.add_parser("select-simulator")
    select.add_argument("inventory", type=Path)
    select.add_argument("--minimum", type=parse_minimum_version, default=(17, 0, 0))
    args = parser.parse_args()
    try:
        if args.command == "prepare-artifacts":
            print(prepare_artifacts_directory(args.path, args.repository_root))
        else:
            payload = json.loads(args.inventory.read_text(encoding="utf-8"))
            udid, state, name = select_simulator(payload, args.minimum)
            print(f"{udid}\t{state}\t{name}")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"FAIL: {error}") from error


if __name__ == "__main__":
    main()
