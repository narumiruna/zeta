from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "check_licenses",
    ROOT / "scripts" / "check-licenses.py",
)
assert SPEC is not None and SPEC.loader is not None
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def pin(
    identity: str,
    repository: str | None = None,
    version: str = "1.2.3",
    revision: str = "revision-hash",
) -> dict[str, object]:
    return {
        "identity": identity,
        "kind": "remoteSourceControl",
        "location": repository or f"https://example.com/{identity}.git",
        "state": {"version": version, "revision": revision},
    }


def create_repository(root: Path, adr: str, pins: list[dict[str, object]]) -> None:
    (root / "LICENSE").write_text("MIT\n", encoding="utf-8")
    adr_path = root / CHECK.LICENSE_REVIEW_PATH
    adr_path.parent.mkdir(parents=True)
    adr_path.write_text(adr, encoding="utf-8")
    if pins:
        (root / "Package.resolved").write_text(
            json.dumps({"version": 3, "pins": pins}), encoding="utf-8"
        )


def review_row(
    identity: str,
    repository: str | None = None,
    version: str = "1.2.3",
    revision: str = "revision-hash",
    license_name: str = "MIT",
    transitive: str = "None",
    advisory: str = "0 published on 2026-08-29",
) -> str:
    values = (
        f"`{identity}`",
        f"`{repository or f'https://example.com/{identity}.git'}`",
        version,
        f"`{revision}`",
        license_name,
        transitive,
        advisory,
    )
    return "| " + " | ".join(values) + " |"


def review_table(*rows: str) -> str:
    joined_rows = "\n".join(rows)
    return f"""## License review and supply-chain pinning

| Identity | Repository | Exact release | Revision | License | Transitive packages | Advisory review |
| --- | --- | --- | --- | --- | --- | --- |
{joined_rows}
"""


class LicenseReviewTests(unittest.TestCase):
    def test_accepts_structured_review_matching_resolved_pin(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            create_repository(
                root,
                f"# ADR\n\n{review_table(review_row('example'))}",
                [pin("example")],
            )

            count = CHECK.check_license_review(root)

        self.assertEqual(count, 1)

    def test_rejects_identity_mentioned_only_before_license_review(self) -> None:
        adr = f"""# ADR

## Decision

The example package is selected.

{review_table()}
"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            create_repository(root, adr, [pin("example")])

            with self.assertRaisesRegex(ValueError, "missing from license ADR"):
                CHECK.check_license_review(root)

    def test_rejects_identity_row_after_license_review_section(self) -> None:
        adr = f"""# ADR

{review_table()}

## Consequences

{review_row("example")}
"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            create_repository(root, adr, [pin("example")])

            with self.assertRaisesRegex(ValueError, "missing from license ADR"):
                CHECK.check_license_review(root)

    def test_rejects_unstructured_identity_in_license_review(self) -> None:
        adr = """# ADR

## License review and supply-chain pinning

The example dependency was considered.

## Consequences

The policy applies.
"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            create_repository(root, adr, [pin("example")])

            with self.assertRaisesRegex(ValueError, "structured license review table"):
                CHECK.check_license_review(root)

    def test_rejects_one_cell_identity_row(self) -> None:
        adr = f"# ADR\n\n{review_table('| `example` |')}"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            create_repository(root, adr, [pin("example")])

            with self.assertRaisesRegex(ValueError, "seven columns"):
                CHECK.check_license_review(root)

    def test_rejects_review_repository_that_does_not_match_pin(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            create_repository(
                root,
                f"# ADR\n\n{review_table(review_row('example', repository='https://example.com/old.git'))}",
                [pin("example")],
            )

            with self.assertRaisesRegex(ValueError, "repository.*does not match"):
                CHECK.check_license_review(root)

    def test_rejects_review_release_or_revision_that_does_not_match_pin(self) -> None:
        cases = (
            (review_row("example", version="1.2.2"), "exact release"),
            (review_row("example", revision="old-hash"), "revision"),
        )
        for row, message in cases:
            with self.subTest(message=message), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                create_repository(
                    root,
                    f"# ADR\n\n{review_table(row)}",
                    [pin("example")],
                )

                with self.assertRaisesRegex(ValueError, f"{message}.*does not match"):
                    CHECK.check_license_review(root)

    def test_rejects_empty_required_review_details(self) -> None:
        rows = (
            review_row("example", license_name=""),
            review_row("example", transitive=""),
            review_row("example", advisory=""),
        )
        for row in rows:
            with self.subTest(row=row), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                create_repository(
                    root,
                    f"# ADR\n\n{review_table(row)}",
                    [pin("example")],
                )

                with self.assertRaisesRegex(ValueError, "empty fields"):
                    CHECK.check_license_review(root)

    def test_accepts_no_resolved_dependencies_without_review_rows(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            create_repository(root, f"# ADR\n\n{review_table()}", [])

            count = CHECK.check_license_review(root)

        self.assertEqual(count, 0)


if __name__ == "__main__":
    unittest.main()
