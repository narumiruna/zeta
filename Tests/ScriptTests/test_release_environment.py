import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CHECK_SCRIPT = REPOSITORY_ROOT / "scripts" / "check-release-environment.sh"


class ReleaseEnvironmentTests(unittest.TestCase):
    def run_check(
        self,
        *,
        architecture: str = "arm64",
        swift_version: str = "6.2.0",
        uv_version: str = "0.9.26",
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            bin_directory = Path(temporary)
            self.write_command(bin_directory, "uname", f'echo "{architecture}"')
            self.write_command(
                bin_directory,
                "swift",
                f'echo "Apple Swift version {swift_version} (swiftlang-fixture)"',
            )
            self.write_command(
                bin_directory,
                "uv",
                f'echo "uv {uv_version} (fixture)"',
            )
            self.write_command(
                bin_directory,
                "sw_vers",
                'echo "ProductName: fixture-macOS"',
            )
            environment = os.environ.copy()
            environment["PATH"] = f"{bin_directory}:/usr/bin:/bin"
            return subprocess.run(
                [str(CHECK_SCRIPT)],
                cwd=REPOSITORY_ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

    def write_command(self, directory: Path, name: str, body: str) -> None:
        command = directory / name
        command.write_text(f"#!/bin/sh\nset -eu\n{body}\n", encoding="utf-8")
        command.chmod(0o755)

    def test_accepts_pinned_arm64_environment(self) -> None:
        result = self.run_check()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("release environment verified", result.stdout)

    def test_accepts_pinned_swift_version_with_omitted_zero_patch(self) -> None:
        result = self.run_check(swift_version="6.2")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("release environment verified", result.stdout)

    def test_rejects_non_arm64_environment(self) -> None:
        result = self.run_check(architecture="x86_64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires arm64", result.stderr)

    def test_rejects_unpinned_swift_version(self) -> None:
        result = self.run_check(swift_version="6.3.3")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires Swift 6.2.0", result.stderr)

    def test_rejects_unpinned_uv_version(self) -> None:
        result = self.run_check(uv_version="0.9.25")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires uv 0.9.26", result.stderr)


if __name__ == "__main__":
    unittest.main()
