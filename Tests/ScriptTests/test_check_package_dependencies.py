from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "check_package_dependencies",
    ROOT / "scripts" / "check-package-dependencies.py",
)
assert SPEC is not None and SPEC.loader is not None
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def dependency(identity: str, kind: str, value: str) -> dict[str, object]:
    return {
        "sourceControl": [
            {
                "identity": identity,
                "requirement": {kind: [value]},
            }
        ]
    }


def write_resolved(path: Path, pins: list[dict[str, object]]) -> None:
    path.write_text(json.dumps({"version": 2, "pins": pins}), encoding="utf-8")


class PackageDependencyPolicyTests(unittest.TestCase):
    def test_accepts_no_dependencies_without_resolved_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            count = CHECK.check_dependency_policy(
                {"dependencies": []}, Path(temporary) / "Package.resolved"
            )

        self.assertEqual(count, 0)

    def test_accepts_exact_release_and_revision_matching_resolved_pins(self) -> None:
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
                    {
                        "identity": "release-package",
                        "state": {"version": "1.2.3", "revision": "release-hash"},
                    },
                    {
                        "identity": "revision-package",
                        "state": {"revision": "0123456789abcdef"},
                    },
                ],
            )

            count = CHECK.check_dependency_policy(manifest, resolved)

        self.assertEqual(count, 2)

    def test_rejects_range_and_branch_requirements(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            resolved = Path(temporary) / "Package.resolved"
            for kind in ("range", "branch"):
                with self.subTest(kind=kind):
                    with self.assertRaisesRegex(ValueError, "exact release or revision"):
                        CHECK.check_dependency_policy(
                            {"dependencies": [dependency("example", kind, "value")]},
                            resolved,
                        )

    def test_requires_resolved_file_for_external_dependency(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "committed Package.resolved"):
                CHECK.check_dependency_policy(
                    {"dependencies": [dependency("example", "exact", "1.2.3")]},
                    Path(temporary) / "Package.resolved",
                )

    def test_requires_direct_dependency_in_resolved_graph(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            resolved = Path(temporary) / "Package.resolved"
            write_resolved(
                resolved,
                [{"identity": "other", "state": {"version": "1.2.3"}}],
            )

            with self.assertRaisesRegex(ValueError, "missing from Package.resolved"):
                CHECK.check_dependency_policy(
                    {"dependencies": [dependency("example", "exact", "1.2.3")]},
                    resolved,
                )

    def test_requires_resolved_state_to_match_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            resolved = Path(temporary) / "Package.resolved"
            write_resolved(
                resolved,
                [{"identity": "example", "state": {"version": "1.2.2"}}],
            )

            with self.assertRaisesRegex(ValueError, "does not match"):
                CHECK.check_dependency_policy(
                    {"dependencies": [dependency("example", "exact", "1.2.3")]},
                    resolved,
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
                    manifest, Path(temporary) / "Package.resolved"
                )


if __name__ == "__main__":
    unittest.main()
