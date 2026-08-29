#!/usr/bin/env python3
import argparse
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
subprocess.run(
    [
        "swift",
        "package",
        "dump-symbol-graph",
        "--skip-synthesized-members",
        "--minimum-access-level",
        "public",
    ],
    cwd=ROOT,
    check=True,
    stdout=subprocess.DEVNULL,
)
paths = sorted((ROOT / ".build").glob("*-apple-macosx/symbolgraph/Zeta*.symbols.json"))
modules: dict[str, list[tuple[str, str]]] = {}
for path in paths:
    module = path.stem.split(".")[0]
    if module.endswith("Tests") or module in {"ZetaPackageTests", "ZetaExecutable", "PiExecutable"}:
        continue
    data = json.loads(path.read_text())
    values: list[tuple[str, str]] = []
    for symbol in data.get("symbols", []):
        title = symbol.get("names", {}).get("title")
        kind = symbol.get("kind", {}).get("displayName")
        if title and kind:
            values.append((title.replace("|", "\\|"), kind))
    modules[module] = sorted(set(values), key=lambda value: (value[1], value[0]))

lines = [
    "# Public Swift symbols",
    "",
    "This file is generated from Swift symbol graphs.",
    "It lists every public declaration included in the release libraries.",
    "Regenerate it with `uv run python scripts/generate-api-docs.py`.",
    "",
]
for module, values in sorted(modules.items()):
    lines += [f"## {module}", "", "| Symbol | Kind |", "| --- | --- |"]
    lines += [f"| `{name}` | {kind} |" for name, kind in values]
    lines.append("")
content = "\n".join(lines).rstrip() + "\n"
output = ROOT / "docs/api/symbols.md"
if args.check:
    if not output.exists() or output.read_text() != content:
        print("public Swift symbol documentation is stale", file=sys.stderr)
        raise SystemExit(1)
    print(f"API documentation verified: {sum(map(len, modules.values()))} symbols across {len(modules)} modules")
else:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content)
    print(f"generated {sum(map(len, modules.values()))} public symbols across {len(modules)} modules")
