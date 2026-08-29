from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "ios_library_check_support",
    ROOT / "scripts" / "ios_library_check_support.py",
)
assert SPEC is not None and SPEC.loader is not None
SUPPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUPPORT)


class ArtifactsDirectoryTests(unittest.TestCase):
    def test_refuses_unmarked_existing_directory_without_removing_contents(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifacts = root / "existing"
            artifacts.mkdir()
            sentinel = artifacts / "preserve.txt"
            sentinel.write_text("preserve", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "not owned by this script"):
                SUPPORT.prepare_artifacts_directory(str(artifacts), str(root))

            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")

    def test_reuses_only_marked_directory_and_clears_previous_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifacts = root / "new"
            self.assertEqual(
                SUPPORT.prepare_artifacts_directory(str(artifacts), str(root)),
                artifacts.resolve(),
            )
            (artifacts / "old.log").write_text("old", encoding="utf-8")
            (artifacts / "old.xcresult").mkdir()

            SUPPORT.prepare_artifacts_directory(str(artifacts), str(root))

            self.assertEqual(
                {path.name for path in artifacts.iterdir()},
                {SUPPORT.ARTIFACT_MARKER},
            )

    def test_refuses_repository_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, "unsafe iOS artifacts directory"):
                SUPPORT.prepare_artifacts_directory(str(root / "child" / ".."), str(root))


class SimulatorSelectionTests(unittest.TestCase):
    def test_ignores_booted_runtime_below_ios_17(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
                    {"state": "Booted", "udid": "old", "name": "Old iPhone"}
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
                    {"state": "Shutdown", "udid": "supported", "name": "Supported iPhone"}
                ],
            }
        }

        self.assertEqual(
            SUPPORT.select_simulator(payload),
            ("supported", "Shutdown", "Supported iPhone"),
        )

    def test_prefers_booted_supported_simulator(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
                    {"state": "Shutdown", "udid": "shutdown", "name": "Shutdown iPhone"}
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                    {"state": "Booted", "udid": "booted", "name": "Booted iPhone"}
                ],
            }
        }

        self.assertEqual(
            SUPPORT.select_simulator(payload),
            ("booted", "Booted", "Booted iPhone"),
        )

    def test_fails_when_only_unsupported_or_malformed_runtimes_exist(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
                    {"state": "Shutdown", "udid": "old", "name": "Old iPhone"}
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-preview": [
                    {"state": "Shutdown", "udid": "preview", "name": "Preview iPhone"}
                ],
            }
        }

        with self.assertRaisesRegex(ValueError, "iOS 17.0-or-newer"):
            SUPPORT.select_simulator(payload)


if __name__ == "__main__":
    unittest.main()
