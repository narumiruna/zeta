#!/usr/bin/env -S uv run python
"""Enforce immutable Swift package requirements and a reproducible resolution graph."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, NamedTuple


class DirectRequirement(NamedTuple):
    identity: str
    pin_kind: str
    location: str
    requirement_kind: str
    value: str


class ResolvedPin(NamedTuple):
    kind: str
    location: str
    state: dict[str, Any]


def load_manifest(path: Path | None, package_path: Path) -> dict[str, Any]:
    if path is not None:
        return json.loads(path.read_text(encoding="utf-8"))
    result = subprocess.run(
        ["swift", "package", "--package-path", str(package_path), "dump-package"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def dependency_origin(
    source_kind: str, record: dict[str, Any], identity: str
) -> tuple[str, str]:
    if source_kind == "registry":
        return "registry", identity

    location = record.get("location")
    if not isinstance(location, dict) or set(location) != {"remote"}:
        raise ValueError(f"dependency {identity!r} has an invalid source-control origin")
    remotes = location["remote"]
    if not isinstance(remotes, list) or len(remotes) != 1:
        raise ValueError(f"dependency {identity!r} has an invalid source-control origin")
    remote = remotes[0]
    if not isinstance(remote, dict) or set(remote) != {"urlString"}:
        raise ValueError(f"dependency {identity!r} has an invalid source-control origin")
    url = remote["urlString"]
    if not isinstance(url, str) or not url:
        raise ValueError(f"dependency {identity!r} has an invalid source-control origin")
    return "remoteSourceControl", url


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
        pin_kind, location = dependency_origin(source_kind, record, identity)
        requirements.append(
            DirectRequirement(
                identity.lower(),
                pin_kind,
                location,
                requirement_kind,
                values[0],
            )
        )

    identities = [requirement.identity for requirement in requirements]
    if len(identities) != len(set(identities)):
        raise ValueError("package manifest contains duplicate dependency identities")
    return requirements


def resolved_pins(path: Path) -> dict[str, ResolvedPin]:
    data = json.loads(path.read_text(encoding="utf-8"))
    pins = data.get("pins", data.get("object", {}).get("pins", []))
    if not isinstance(pins, list):
        raise ValueError("Package.resolved has no pin list")

    result: dict[str, ResolvedPin] = {}
    for index, pin in enumerate(pins):
        if not isinstance(pin, dict):
            raise ValueError(f"resolved pin {index} is invalid")
        identity = pin.get("identity") or pin.get("package")
        repository_url = pin.get("repositoryURL")
        kind = pin.get("kind") or (
            "remoteSourceControl" if isinstance(repository_url, str) else None
        )
        location = pin.get("location") or repository_url
        state = pin.get("state")
        if not isinstance(identity, str) or not identity:
            raise ValueError(f"resolved pin {index} has no identity")
        if not isinstance(kind, str) or not kind:
            raise ValueError(f"resolved pin {identity!r} has no kind")
        if not isinstance(location, str) or not location:
            raise ValueError(f"resolved pin {identity!r} has no location")
        if not isinstance(state, dict) or not state:
            raise ValueError(f"resolved pin {identity!r} has no state")
        normalized = identity.lower()
        if normalized in result:
            raise ValueError(f"Package.resolved contains duplicate identity {identity!r}")
        result[normalized] = ResolvedPin(kind, location, state)
    return result


def dependency_graph_identities(graph: Any) -> set[str]:
    if not isinstance(graph, dict):
        raise ValueError("resolved dependency graph root is invalid")
    root_dependencies = graph.get("dependencies")
    if not isinstance(root_dependencies, list):
        raise ValueError("resolved dependency graph root has no dependency list")

    identities: set[str] = set()
    pending = list(root_dependencies)
    while pending:
        package = pending.pop()
        if not isinstance(package, dict):
            raise ValueError("resolved dependency graph contains an invalid package")
        identity = package.get("identity")
        dependencies = package.get("dependencies")
        if not isinstance(identity, str) or not identity:
            raise ValueError("resolved dependency graph contains a package without identity")
        if not isinstance(dependencies, list):
            raise ValueError(
                f"resolved dependency graph package {identity!r} has no dependency list"
            )
        identities.add(identity.lower())
        pending.extend(dependencies)
    return identities


def verify_version_revision(identity: str, pin: ResolvedPin) -> None:
    if pin.kind != "remoteSourceControl":
        return
    version = pin.state.get("version")
    if version is None:
        return
    revision = pin.state.get("revision")
    if not isinstance(version, str) or not version:
        raise ValueError(f"resolved version for {identity!r} is invalid")
    if not isinstance(revision, str) or not revision:
        raise ValueError(
            f"resolved revision for versioned package {identity!r} is invalid"
        )

    tag_names = (version, f"v{version}")
    tag_refs = tuple(f"refs/tags/{tag}" for tag in tag_names)
    expected_refs = set(tag_refs) | {f"{tag_ref}^{{}}" for tag_ref in tag_refs}
    result = subprocess.run(
        ["git", "ls-remote", "--tags", pin.location, *sorted(expected_refs)],
        check=True,
        capture_output=True,
        text=True,
    )
    remote_refs: dict[str, str] = {}
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) != 2 or fields[1] not in expected_refs or not fields[0]:
            raise ValueError(f"release tag response for {identity!r} is invalid")
        remote_refs[fields[1]] = fields[0]

    tag_revisions = {
        remote_refs.get(f"{tag_ref}^{{}}", remote_refs[tag_ref])
        for tag_ref in tag_refs
        if tag_ref in remote_refs
    }
    if not tag_revisions:
        raise ValueError(
            f"release tag for {identity!r} version {version!r} was not found"
        )
    if len(tag_revisions) != 1:
        raise ValueError(
            f"release tags for {identity!r} version {version!r} are ambiguous"
        )
    tag_revision = tag_revisions.pop()
    if revision.lower() != tag_revision.lower():
        raise ValueError(
            f"release tag for {identity!r} version {version!r} resolves to "
            f"{tag_revision!r}, not committed revision {revision!r}"
        )


def independently_resolve(
    package_path: Path, resolved_path: Path
) -> dict[str, ResolvedPin]:
    manifest_path = package_path / "Package.swift"
    if not manifest_path.is_file():
        raise ValueError(f"package manifest is missing from {package_path}")
    if not resolved_path.is_file():
        raise ValueError("external dependencies require a committed Package.resolved")

    with tempfile.TemporaryDirectory(prefix="zeta-package-resolution-") as temporary:
        resolution_root = Path(temporary)
        for candidate in package_path.glob("Package*.swift"):
            shutil.copy2(candidate, resolution_root / candidate.name)
        for directory_name in ("Sources", "Tests", "Plugins"):
            source_directory = package_path / directory_name
            if source_directory.is_dir():
                (resolution_root / directory_name).symlink_to(
                    source_directory.resolve(),
                    target_is_directory=True,
                )
        shutil.copy2(resolved_path, resolution_root / "Package.resolved")
        configuration = package_path / ".swiftpm" / "configuration"
        if configuration.is_dir():
            shutil.copytree(
                configuration,
                resolution_root / ".swiftpm" / "configuration",
            )
        swift_package = [
            "swift",
            "package",
            "--package-path",
            str(resolution_root),
            "--scratch-path",
            str(resolution_root / ".build"),
            "--force-resolved-versions",
        ]
        subprocess.run([*swift_package, "resolve"], check=True)
        graph_result = subprocess.run(
            [*swift_package, "show-dependencies", "--format", "json"],
            check=True,
            capture_output=True,
            text=True,
        )
        pins = resolved_pins(resolution_root / "Package.resolved")
        identities = dependency_graph_identities(json.loads(graph_result.stdout))
        unpinned = sorted(identities - pins.keys())
        if unpinned:
            raise ValueError(
                f"resolved dependency graph contains unpinned packages: {unpinned}"
            )
        reachable_pins = {identity: pins[identity] for identity in identities}
        for identity, pin in sorted(reachable_pins.items()):
            verify_version_revision(identity, pin)
        return reachable_pins


def compare_resolution_graphs(
    committed: dict[str, ResolvedPin], independent: dict[str, ResolvedPin]
) -> None:
    missing = sorted(independent.keys() - committed.keys())
    unexpected = sorted(committed.keys() - independent.keys())
    changed = sorted(
        identity
        for identity in committed.keys() & independent.keys()
        if committed[identity] != independent[identity]
    )
    if missing or unexpected or changed:
        details = []
        if missing:
            details.append(f"missing pins: {missing}")
        if unexpected:
            details.append(f"unexpected pins: {unexpected}")
        if changed:
            details.append(f"changed pins: {changed}")
        raise ValueError(
            "committed Package.resolved does not match an independent resolution ("
            + "; ".join(details)
            + ")"
        )


def check_dependency_policy(
    manifest: dict[str, Any],
    resolved_path: Path,
    independent_pins: dict[str, ResolvedPin],
) -> int:
    requirements = direct_requirements(manifest)
    if not requirements:
        if resolved_path.exists():
            compare_resolution_graphs(resolved_pins(resolved_path), independent_pins)
        return 0
    if not resolved_path.is_file():
        raise ValueError("external dependencies require a committed Package.resolved")

    pins = resolved_pins(resolved_path)
    for requirement in requirements:
        pin = pins.get(requirement.identity)
        if pin is None:
            raise ValueError(
                f"direct dependency {requirement.identity!r} is missing from Package.resolved"
            )
        if pin.kind != requirement.pin_kind or pin.location != requirement.location:
            raise ValueError(
                f"resolved origin for {requirement.identity!r} does not match "
                f"the manifest origin {requirement.location!r}"
            )
        state_key = "version" if requirement.requirement_kind == "exact" else "revision"
        if pin.state.get(state_key) != requirement.value:
            raise ValueError(
                f"resolved {state_key} for {requirement.identity!r} does not match "
                f"the manifest requirement {requirement.value!r}"
            )
    compare_resolution_graphs(pins, independent_pins)
    return len(requirements)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--package-path", type=Path, default=Path.cwd())
    parser.add_argument("--resolved", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.manifest is None and not (args.package_path / "Package.swift").is_file():
        print("SKIP package dependency policy: Package.swift is absent")
        return
    try:
        manifest = load_manifest(args.manifest, args.package_path)
        requirements = direct_requirements(manifest)
        resolved_path = args.resolved or args.package_path / "Package.resolved"
        independent_pins = (
            independently_resolve(args.package_path, resolved_path)
            if requirements
            else {}
        )
        count = check_dependency_policy(manifest, resolved_path, independent_pins)
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"package dependency policy failed: {error}") from error
    print(f"package dependency policy verified: {count} direct dependencies")


if __name__ == "__main__":
    main()
