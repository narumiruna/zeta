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


def create_repository(root: Path, adr: str, identities: list[str]) -> None:
    (root / "LICENSE").write_text("MIT\n", encoding="utf-8")
    adr_path = root / CHECK.LICENSE_REVIEW_PATH
    adr_path.parent.mkdir(parents=True)
    adr_path.write_text(adr, encoding="utf-8")
    if identities:
        pins = [
            {"identity": identity, "state": {"version": "1.2.3"}}
            for identity in identities
        ]
        (root / "Package.resolved").write_text(
            json.dumps({"version": 2, "pins": pins}), encoding="utf-8"
        )


def review_table(*identities: str) -> str:
    rows = "\n".join(
        f"| `{identity}` | https://example.com/{identity} | 1.2.3 | MIT | None |"
        for identity in identities
    )
    return f"""## License review and supply-chain pinning

| Identity | Repository | Exact release | License | Transitive packages |
| --- | --- | --- | --- | --- |
{rows}
"""


class LicenseReviewTests(unittest.TestCase):
    def test_accepts_explicit_identity_row_in_license_review(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            create_repository(root, f"# ADR\n\n{review_table('example')}", ["example"])

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
            create_repository(root, adr, ["example"])

            with self.assertRaisesRegex(ValueError, "missing from license ADR"):
                CHECK.check_license_review(root)

    def test_rejects_identity_row_after_license_review_section(self) -> None:
        adr = f"""# ADR

{review_table()}

## Consequences

| `example` | not a license review row |
"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            create_repository(root, adr, ["example"])

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
            create_repository(root, adr, ["example"])

            with self.assertRaisesRegex(ValueError, "missing from license ADR"):
                CHECK.check_license_review(root)

    def test_accepts_no_resolved_dependencies_without_identity_rows(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            create_repository(root, f"# ADR\n\n{review_table()}", [])

            count = CHECK.check_license_review(root)

        self.assertEqual(count, 0)


if __name__ == "__main__":
    unittest.main()
