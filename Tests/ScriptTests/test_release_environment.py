import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CHECK_SCRIPT = REPOSITORY_ROOT / "scripts" / "check-release-environment.sh"
BUILD_SOURCE_SCRIPT = REPOSITORY_ROOT / "scripts" / "build-source-archive.sh"
TOOL_VERSIONS = REPOSITORY_ROOT / ".tool-versions"


class ReleaseEnvironmentTests(unittest.TestCase):
    def run_check(
        self,
        *,
        architecture: str = "arm64",
        swift_version: str = "6.2.0",
        xcode_swift_version: str = "6.2.0",
        uv_version: str = "0.9.26",
        dirty_path: str | None = None,
        ignored_path: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_root = Path(temporary)
            repository = self.create_repository(temporary_root)
            if dirty_path is not None:
                dirty_file = repository / dirty_path
                dirty_file.parent.mkdir(parents=True, exist_ok=True)
                dirty_file.write_text("fixture\n", encoding="utf-8")
            if ignored_path is not None:
                exclude = repository / ".git" / "info" / "exclude"
                with exclude.open("a", encoding="utf-8") as file:
                    file.write(f"/{ignored_path}\n")
                ignored_file = repository / ignored_path
                ignored_file.parent.mkdir(parents=True, exist_ok=True)
                ignored_file.write_text("fixture\n", encoding="utf-8")
            bin_directory = temporary_root / "bin"
            bin_directory.mkdir()
            self.write_command(bin_directory, "uname", f'echo "{architecture}"')
            self.write_command(
                bin_directory,
                "swift",
                f'echo "Apple Swift version {swift_version} (swiftlang-fixture)"',
            )
            self.write_command(
                bin_directory,
                "xcrun",
                """if [ "${1:-}" = "swift" ] && [ "${2:-}" = "--version" ]; then
  echo "Apple Swift version %s (swiftlang-xcode-fixture)"
else
  echo "unexpected xcrun arguments" >&2
  exit 2
fi"""
                % xcode_swift_version,
            )
            self.write_command(
                bin_directory,
                "xcodebuild",
                'printf "Xcode 26.0\\nBuild version fixture\\n"',
            )
            self.write_command(bin_directory, "uv", f'echo "uv {uv_version} (fixture)"')
            self.write_command(
                bin_directory,
                "sw_vers",
                'echo "ProductName: fixture-macOS"',
            )
            environment = os.environ.copy()
            environment["PATH"] = f"{bin_directory}:/usr/bin:/bin"
            return subprocess.run(
                [str(repository / "scripts" / CHECK_SCRIPT.name)],
                cwd=repository,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

    def create_repository(self, temporary_root: Path) -> Path:
        repository = temporary_root / "repository"
        scripts = repository / "scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(CHECK_SCRIPT, scripts / CHECK_SCRIPT.name)
        shutil.copy2(BUILD_SOURCE_SCRIPT, scripts / BUILD_SOURCE_SCRIPT.name)
        shutil.copy2(TOOL_VERSIONS, repository / TOOL_VERSIONS.name)
        subprocess.run(["git", "init", "-q", str(repository)], check=True)
        subprocess.run(["git", "-C", str(repository), "add", "."], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(repository),
                "-c",
                "commit.gpgsign=false",
                "-c",
                "user.name=fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "commit",
                "-qm",
                "fixture",
            ],
            check=True,
        )
        return repository

    def write_command(self, directory: Path, name: str, body: str) -> None:
        command = directory / name
        command.write_text(f"#!/bin/sh\nset -eu\n{body}\n", encoding="utf-8")
        command.chmod(0o755)

    def test_accepts_pinned_arm64_environment(self) -> None:
        result = self.run_check()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("release environment verified", result.stdout)

    def test_accepts_pinned_swift_version_with_omitted_zero_patch(self) -> None:
        result = self.run_check(swift_version="6.2", xcode_swift_version="6.2")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("release environment verified", result.stdout)

    def test_rejects_non_arm64_environment(self) -> None:
        result = self.run_check(architecture="x86_64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires arm64", result.stderr)

    def test_rejects_unpinned_swift_version(self) -> None:
        result = self.run_check(swift_version="6.3.3")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PATH Swift 6.2.0", result.stderr)

    def test_rejects_swift_version_suffixes(self) -> None:
        for version in ("6.2-dev", "6.2.0.1"):
            with self.subTest(version=version):
                result = self.run_check(swift_version=version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"found {version}", result.stderr)

    def test_rejects_unpinned_xcode_swift_version(self) -> None:
        result = self.run_check(xcode_swift_version="6.3.3")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Xcode Swift 6.2.0", result.stderr)

    def test_rejects_unpinned_uv_version(self) -> None:
        result = self.run_check(uv_version="0.9.25")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires uv 0.9.26", result.stderr)

    def test_rejects_ignored_release_input(self) -> None:
        result = self.run_check(ignored_path="Sources/Ignored.swift")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ignored release inputs", result.stderr)

    def test_rejects_untracked_release_input(self) -> None:
        result = self.run_check(dirty_path="Sources/Untracked.swift")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean checkout", result.stderr)

    def test_source_archive_accepts_clean_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_root = Path(temporary)
            repository = self.create_repository(temporary_root)
            archive = temporary_root / "source.tar.gz"
            result = subprocess.run(
                [str(repository / "scripts" / BUILD_SOURCE_SCRIPT.name), str(archive)],
                cwd=repository,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(archive.is_file())

    def test_source_archive_rejects_ignored_release_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_root = Path(temporary)
            repository = self.create_repository(temporary_root)
            exclude = repository / ".git" / "info" / "exclude"
            with exclude.open("a", encoding="utf-8") as file:
                file.write("/docs/ignored.md\n")
            ignored = repository / "docs" / "ignored.md"
            ignored.parent.mkdir()
            ignored.write_text("fixture\n", encoding="utf-8")
            result = subprocess.run(
                [
                    str(repository / "scripts" / BUILD_SOURCE_SCRIPT.name),
                    str(temporary_root / "source.tar.gz"),
                ],
                cwd=repository,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ignored release inputs", result.stderr)

    def test_source_archive_rejects_untracked_release_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_root = Path(temporary)
            repository = self.create_repository(temporary_root)
            untracked = repository / "docs" / "untracked.md"
            untracked.parent.mkdir()
            untracked.write_text("fixture\n", encoding="utf-8")
            result = subprocess.run(
                [
                    str(repository / "scripts" / BUILD_SOURCE_SCRIPT.name),
                    str(temporary_root / "source.tar.gz"),
                ],
                cwd=repository,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean checkout", result.stderr)


if __name__ == "__main__":
    unittest.main()
