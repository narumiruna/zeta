from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "check_package_dependencies",
    ROOT / "scripts" / "check-package-dependencies.py",
)
assert SPEC is not None and SPEC.loader is not None
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def dependency(
    identity: str,
    requirement_kind: str,
    value: str,
    location: str | None = None,
) -> dict[str, object]:
    return {
        "sourceControl": [
            {
                "identity": identity,
                "location": {
                    "remote": [
                        {"urlString": location or f"https://example.com/{identity}.git"}
                    ]
                },
                "requirement": {requirement_kind: [value]},
            }
        ]
    }


def pin(
    identity: str,
    state: dict[str, str],
    location: str | None = None,
    kind: str = "remoteSourceControl",
) -> dict[str, object]:
    return {
        "identity": identity,
        "kind": kind,
        "location": location or f"https://example.com/{identity}.git",
        "state": state,
    }


def write_resolved(path: Path, pins: list[dict[str, object]]) -> None:
    path.write_text(json.dumps({"version": 3, "pins": pins}), encoding="utf-8")


def parsed_pins(path: Path) -> dict[str, object]:
    return CHECK.resolved_pins(path)


def graph_package(identity: str, *dependencies: dict[str, object]) -> dict[str, object]:
    return {"identity": identity, "dependencies": list(dependencies)}


def dependency_graph(*dependencies: dict[str, object]) -> dict[str, object]:
    return {"identity": "root", "dependencies": list(dependencies)}


def lightweight_tag(version: str, revision: str) -> str:
    return f"{revision}\trefs/tags/{version}\n"


def annotated_tag(version: str, revision: str) -> str:
    return (
        f"tag-object\trefs/tags/v{version}\n"
        f"{revision}\trefs/tags/v{version}^{{}}\n"
    )


class PackageDependencyPolicyTests(unittest.TestCase):
    def test_accepts_no_dependencies_without_resolved_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            count = CHECK.check_dependency_policy(
                {"dependencies": []},
                Path(temporary) / "Package.resolved",
                {},
            )

        self.assertEqual(count, 0)

    def test_rejects_stale_resolved_graph_without_manifest_dependencies(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            resolved = Path(temporary) / "Package.resolved"
            write_resolved(
                resolved,
                [pin("stale", {"version": "1.2.3", "revision": "stale-hash"})],
            )

            with self.assertRaisesRegex(ValueError, "unexpected pins:.*stale"):
                CHECK.check_dependency_policy({"dependencies": []}, resolved, {})

    def test_accepts_exact_release_and_revision_matching_complete_graph(self) -> None:
        manifest = {
            "dependencies": [
                dependency("release-package", "exact", "1.2.3"),
                dependency("revision-package", "revision", "0123456789abcdef"),
            ]
        }
        with tempfile.TemporaryDirectory() as temporary:
            resolved = Path(temporary) / "Package.resolved"
            write_resolved(
                resolved,
                [
                    pin(
                        "release-package",
                        {"version": "1.2.3", "revision": "release-hash"},
                    ),
                    pin(
                        "revision-package",
                        {"revision": "0123456789abcdef"},
                    ),
                ],
            )

            count = CHECK.check_dependency_policy(
                manifest, resolved, parsed_pins(resolved)
            )

        self.assertEqual(count, 2)

    def test_accepts_registry_origin_matching_resolved_pin(self) -> None:
        manifest = {
            "dependencies": [
                {
                    "registry": [
                        {
                            "identity": "mona.LinkedList",
                            "requirement": {"exact": ["1.1.1"]},
                        }
                    ]
                }
            ]
        }
        with tempfile.TemporaryDirectory() as temporary:
            resolved = Path(temporary) / "Package.resolved"
            write_resolved(
                resolved,
                [
                    pin(
                        "mona.LinkedList",
                        {"version": "1.1.1"},
                        location="mona.LinkedList",
                        kind="registry",
                    )
                ],
            )

            count = CHECK.check_dependency_policy(
                manifest, resolved, parsed_pins(resolved)
            )

        self.assertEqual(count, 1)

    def test_rejects_range_and_branch_requirements(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            resolved = Path(temporary) / "Package.resolved"
            for kind in ("range", "branch"):
                with self.subTest(kind=kind):
                    with self.assertRaisesRegex(ValueError, "exact release or revision"):
                        CHECK.check_dependency_policy(
                            {"dependencies": [dependency("example", kind, "value")]},
                            resolved,
                            {},
                        )

    def test_requires_resolved_file_for_external_dependency(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "committed Package.resolved"):
                CHECK.check_dependency_policy(
                    {
                        "dependencies": [
                            dependency("example", "exact", "1.2.3")
                        ]
                    },
                    Path(temporary) / "Package.resolved",
                    {},
                )

    def test_requires_direct_dependency_in_resolved_graph(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            resolved = Path(temporary) / "Package.resolved"
            write_resolved(
                resolved,
                [pin("other", {"version": "1.2.3", "revision": "other-hash"})],
            )

            with self.assertRaisesRegex(ValueError, "missing from Package.resolved"):
                CHECK.check_dependency_policy(
                    {
                        "dependencies": [
                            dependency("example", "exact", "1.2.3")
                        ]
                    },
                    resolved,
                    parsed_pins(resolved),
                )

    def test_requires_resolved_state_to_match_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            resolved = Path(temporary) / "Package.resolved"
            write_resolved(
                resolved,
                [pin("example", {"version": "1.2.2", "revision": "hash"})],
            )

            with self.assertRaisesRegex(ValueError, "does not match"):
                CHECK.check_dependency_policy(
                    {
                        "dependencies": [
                            dependency("example", "exact", "1.2.3")
                        ]
                    },
                    resolved,
                    parsed_pins(resolved),
                )

    def test_requires_resolved_origin_to_match_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            resolved = Path(temporary) / "Package.resolved"
            write_resolved(
                resolved,
                [
                    pin(
                        "example",
                        {"version": "1.2.3", "revision": "hash"},
                        location="https://example.com/original.git",
                    )
                ],
            )

            with self.assertRaisesRegex(ValueError, "resolved origin"):
                CHECK.check_dependency_policy(
                    {
                        "dependencies": [
                            dependency(
                                "example",
                                "exact",
                                "1.2.3",
                                location="https://example.com/replacement.git",
                            )
                        ]
                    },
                    resolved,
                    parsed_pins(resolved),
                )

    def test_independent_resolution_preserves_package_registry_configuration(
        self,
    ) -> None:
        registry_configuration = {
            "registries": {"[default]": {"url": "https://packages.example.com"}},
            "version": 1,
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Package.swift").write_text(
                "// synthetic manifest\n",
                encoding="utf-8",
            )
            resolved = root / "Package.resolved"
            write_resolved(resolved, [])
            configuration = root / ".swiftpm" / "configuration"
            configuration.mkdir(parents=True)
            (configuration / "registries.json").write_text(
                json.dumps(registry_configuration),
                encoding="utf-8",
            )

            def resolve(command: list[str], **_: object) -> object:
                resolution_root = Path(command[command.index("--package-path") + 1])
                copied_registry = (
                    resolution_root
                    / ".swiftpm"
                    / "configuration"
                    / "registries.json"
                )
                self.assertEqual(
                    json.loads(copied_registry.read_text(encoding="utf-8")),
                    registry_configuration,
                )
                graph = dependency_graph() if "show-dependencies" in command else None
                return mock.Mock(stdout=json.dumps(graph) if graph else None)

            with mock.patch.object(CHECK.subprocess, "run", side_effect=resolve):
                pins = CHECK.independently_resolve(root, resolved)

        self.assertEqual(pins, {})

    def test_independent_resolution_uses_committed_transitive_versions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Package.swift").write_text(
                "// synthetic manifest\n",
                encoding="utf-8",
            )
            resolved = root / "Package.resolved"
            committed_pins = [
                pin("direct", {"version": "1.0.0", "revision": "direct-hash"}),
                pin(
                    "transitive",
                    {"version": "1.0.0", "revision": "transitive-hash"},
                ),
            ]
            write_resolved(resolved, committed_pins)
            expected_pins = parsed_pins(resolved)

            graph = dependency_graph(
                graph_package("direct", graph_package("transitive"))
            )

            def resolve(command: list[str], **_: object) -> object:
                if command[:3] == ["git", "ls-remote", "--tags"]:
                    if command[3].endswith("direct.git"):
                        return mock.Mock(
                            stdout=lightweight_tag("1.0.0", "direct-hash")
                        )
                    if command[3].endswith("transitive.git"):
                        return mock.Mock(
                            stdout=annotated_tag("1.0.0", "transitive-hash")
                        )
                    self.fail(f"unexpected tag query: {command}")
                resolution_root = Path(command[command.index("--package-path") + 1])
                self.assertEqual(
                    parsed_pins(resolution_root / "Package.resolved"),
                    expected_pins,
                )
                self.assertIn("--force-resolved-versions", command)
                output = json.dumps(graph) if "show-dependencies" in command else None
                return mock.Mock(stdout=output)

            with mock.patch.object(CHECK.subprocess, "run", side_effect=resolve):
                pins = CHECK.independently_resolve(root, resolved)

        self.assertEqual(pins, expected_pins)

    def test_rejects_altered_revision_for_reachable_version_pin(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Package.swift").write_text(
                "// synthetic manifest\n",
                encoding="utf-8",
            )
            resolved = root / "Package.resolved"
            write_resolved(
                resolved,
                [pin("direct", {"version": "1.0.0", "revision": "altered-hash"})],
            )
            graph = dependency_graph(graph_package("direct"))

            def resolve(command: list[str], **_: object) -> object:
                if command[:3] == ["git", "ls-remote", "--tags"]:
                    return mock.Mock(stdout=lightweight_tag("1.0.0", "real-hash"))
                output = json.dumps(graph) if "show-dependencies" in command else None
                return mock.Mock(stdout=output)

            with mock.patch.object(CHECK.subprocess, "run", side_effect=resolve):
                with self.assertRaisesRegex(
                    ValueError,
                    "resolves to 'real-hash', not committed revision 'altered-hash'",
                ):
                    CHECK.independently_resolve(root, resolved)

    def test_rejects_stale_pin_outside_forced_dependency_graph(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Package.swift").write_text(
                "// synthetic manifest\n",
                encoding="utf-8",
            )
            resolved = root / "Package.resolved"
            write_resolved(
                resolved,
                [
                    pin("direct", {"version": "1.0.0", "revision": "direct-hash"}),
                    pin(
                        "transitive",
                        {"version": "1.0.0", "revision": "transitive-hash"},
                    ),
                    pin("stale", {"version": "2.0.0", "revision": "stale-hash"}),
                ],
            )
            graph = dependency_graph(
                graph_package("direct", graph_package("transitive"))
            )

            def resolve(command: list[str], **_: object) -> object:
                if command[:3] == ["git", "ls-remote", "--tags"]:
                    self.assertNotIn("stale.git", command[3])
                    revision = (
                        "direct-hash"
                        if command[3].endswith("direct.git")
                        else "transitive-hash"
                    )
                    return mock.Mock(stdout=lightweight_tag("1.0.0", revision))
                output = json.dumps(graph) if "show-dependencies" in command else None
                return mock.Mock(stdout=output)

            with mock.patch.object(CHECK.subprocess, "run", side_effect=resolve):
                forced_pins = CHECK.independently_resolve(root, resolved)

            with self.assertRaisesRegex(ValueError, "unexpected pins:.*stale"):
                CHECK.check_dependency_policy(
                    {"dependencies": [dependency("direct", "exact", "1.0.0")]},
                    resolved,
                    forced_pins,
                )

    def test_requires_complete_independently_resolved_graph(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            committed = root / "committed.json"
            independent = root / "independent.json"
            direct = pin(
                "example", {"version": "1.2.3", "revision": "direct-hash"}
            )
            transitive = pin(
                "transitive", {"version": "4.5.6", "revision": "transitive-hash"}
            )
            write_resolved(committed, [direct])
            write_resolved(independent, [direct, transitive])

            with self.assertRaisesRegex(ValueError, "missing pins:.*transitive"):
                CHECK.check_dependency_policy(
                    {
                        "dependencies": [
                            dependency("example", "exact", "1.2.3")
                        ]
                    },
                    committed,
                    parsed_pins(independent),
                )

    def test_rejects_nonimmutable_filesystem_dependency(self) -> None:
        manifest = {
            "dependencies": [
                {"fileSystem": [{"identity": "example", "path": "../Example"}]}
            ]
        }
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "unsupported 'fileSystem'"):
                CHECK.check_dependency_policy(
                    manifest,
                    Path(temporary) / "Package.resolved",
                    {},
                )


if __name__ == "__main__":
    unittest.main()
