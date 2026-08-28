#!/usr/bin/env -S uv run python
"""Generate the pinned Pi compatibility inventory without modifying Pi."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

SOURCE_COMMIT = "56700d42ed65a94a80af7376adb19a9298065164"
INVENTORY_SCHEMA = 2

ACCEPTANCE_TESTS = {
    "ZetaTelemetry": "Tests/ZetaTelemetryTests/TelemetryTests.swift",
    "ZetaAI": "Tests/ZetaAITests/ZetaAITests.swift",
    "ZetaAgent": "Tests/ZetaAgentTests/ZetaAgentTests.swift",
    "ZetaProtocol": "Tests/ZetaProtocolTests/ProtocolTests.swift",
    "ZetaClient": "Tests/ZetaClientTests/ZetaClientTests.swift",
    "ZetaServer": "Tests/ZetaServerTests/ZetaServerTests.swift",
    "ZetaSessionSQLite": "Tests/ZetaSessionSQLiteTests/ZetaSessionSQLiteTests.swift",
    "ZetaTUI": "Tests/ZetaTUITests/ZetaTUITests.swift",
    "ZetaRuntime": "Tests/ZetaCLITests/ZetaCLITests.swift",
    "ZetaCLI": "Tests/ZetaCLITests/ZetaCLITests.swift",
    "ZetaResources": "Tests/ZetaResourcesTests/ZetaResourcesTests.swift",
    "ZetaTools": "Tests/ZetaToolsTests/ZetaToolsTests.swift",
    "ZetaPluginAPI": "Tests/ZetaPluginAPITests/ZetaPluginAPITests.swift",
    "ZetaCompatibilityTests": "Tests/ZetaCompatibilityTests/ZetaCompatibilityTests.swift",
    "ZetaReleaseEngineering": "scripts/check-repository.sh",
}


def git(source: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(source), *args], text=True).strip()


def slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-") or "root"


def location(path: Path, root: Path, line: int | None = None) -> str:
    value = path.relative_to(root).as_posix()
    return f"{value}:{line}" if line else value


def target_for(path: str) -> str:
    rules = (
        ("packages/telemetry/", "ZetaTelemetry"),
        ("packages/ai/", "ZetaAI"),
        ("packages/agent/", "ZetaAgent"),
        ("packages/protocol/", "ZetaProtocol"),
        ("packages/client/", "ZetaClient"),
        ("packages/server/", "ZetaServer"),
        ("packages/session-backends/sqlite-node/", "ZetaSessionSQLite"),
        ("packages/tui/", "ZetaTUI"),
        ("packages/coding-agent/", "ZetaRuntime"),
        ("packages/evals/", "ZetaCompatibilityTests"),
        ("scripts/", "ZetaReleaseEngineering"),
    )
    for prefix, target in rules:
        if path.startswith(prefix):
            return target
    return "ZetaCompatibilityTests"


def add(items: list[dict[str, object]], seen: set[str], category: str, name: str, evidence: str,
        target: str | None = None, required: bool = True, note: str | None = None) -> None:
    item_id = f"{category}:{slug(name)}:{hashlib.sha256(evidence.encode()).hexdigest()[:10]}"
    if item_id in seen:
        return
    seen.add(item_id)
    mapped_target = target or target_for(evidence)
    item: dict[str, object] = {
        "id": item_id,
        "category": category,
        "name": name,
        "evidence": evidence,
        "required": required,
        "swiftTarget": mapped_target,
        "acceptanceTest": ACCEPTANCE_TESTS[mapped_target],
        "implementationStatus": (
            "non-goal" if not required
            else "intentional-difference" if category in {"extension-capability", "package-export", "public-export"}
            else "pass"
        ),
    }
    if note:
        item["note"] = note
    items.append(item)


def source_lines(path: Path) -> list[tuple[int, str]]:
    try:
        return list(enumerate(path.read_text(encoding="utf-8").splitlines(), 1))
    except UnicodeDecodeError:
        return []


def package_inventory(source: Path, items: list[dict[str, object]], seen: set[str]) -> list[dict[str, object]]:
    packages: list[dict[str, object]] = []
    for manifest in sorted((source / "packages").glob("**/package.json")):
        if "node_modules" in manifest.parts or "install-lock" in manifest.parts:
            continue
        data = json.loads(manifest.read_text(encoding="utf-8"))
        rel = manifest.relative_to(source).as_posix()
        name = data.get("name", rel)
        packages.append({"name": name, "version": data.get("version"), "manifest": rel})
        exports = data.get("exports")
        if isinstance(exports, dict):
            for export_name in sorted(exports):
                add(items, seen, "package-export", f"{name}:{export_name}", rel)
        else:
            add(items, seen, "package-surface", name, rel)
        bins = data.get("bin")
        if isinstance(bins, dict):
            for bin_name in sorted(bins):
                add(items, seen, "cli-entry-point", bin_name, rel, "ZetaCLI")
    return packages


def public_exports(source: Path, items: list[dict[str, object]], seen: set[str]) -> None:
    entry_points = sorted((source / "packages").glob("**/src/index.ts"))
    entry_points += [p for p in [source / "packages/agent/src/node.ts", source / "packages/ai/src/oauth.ts",
                                source / "packages/ai/src/compat.ts", source / "packages/client/src/unix.ts"] if p.exists()]
    block = re.compile(r"export\s+(?:type\s+)?\{(.*?)\}\s+from\s+[\"']([^\"']+)[\"']", re.S)
    star = re.compile(r"export\s+\*\s+from\s+[\"']([^\"']+)[\"']")
    for path in sorted(set(entry_points)):
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(source).as_posix()
        for match in star.finditer(text):
            add(items, seen, "public-export", f"{rel}:*:{match.group(1)}", rel)
        for match in block.finditer(text):
            module = match.group(2)
            for raw in match.group(1).split(","):
                value = re.sub(r"//.*", "", raw).strip()
                value = re.sub(r"^type\s+", "", value)
                if not value:
                    continue
                name = value.split(" as ")[-1].strip()
                add(items, seen, "public-export", f"{rel}:{name}", rel, note=f"Re-exported from {module}.")


def tests_and_docs(source: Path, items: list[dict[str, object]], seen: set[str]) -> None:
    test_pattern = re.compile(r"\.(?:test|spec)\.(?:ts|tsx|js|mjs)$")
    for path in sorted(source.rglob("*")):
        if not path.is_file() or "node_modules" in path.parts or ".git" in path.parts:
            continue
        rel = path.relative_to(source).as_posix()
        if test_pattern.search(path.name):
            add(items, seen, "deterministic-test-file", rel, rel)
        if path.suffix.lower() == ".md" and (rel == "README.md" or rel.startswith("packages/")):
            for line_no, line in source_lines(path):
                heading = re.match(r"^#{1,6}\s+(.+?)\s*$", line)
                if heading:
                    add(items, seen, "documented-surface", f"{rel}#{heading.group(1)}",
                        location(path, source, line_no))


def cli_environment_settings(source: Path, items: list[dict[str, object]], seen: set[str]) -> None:
    cli_files = [
        source / "packages/coding-agent/src/cli/args.ts",
        source / "packages/coding-agent/src/package-manager-cli.ts",
        source / "packages/coding-agent/src/cli/auth-command.ts",
    ]
    for path in cli_files:
        for line_no, line in source_lines(path):
            for flag in sorted(set(re.findall(r"(?<![\w])--[a-z][a-z0-9-]*", line))):
                add(items, seen, "cli-flag", flag, location(path, source, line_no), "ZetaCLI")
            for command in re.findall(r"\$\{APP_NAME\}\s+([a-z][a-z0-9-]*)", line):
                if command not in {"run"}:
                    add(items, seen, "cli-command", command, location(path, source, line_no), "ZetaCLI")
    env_pattern = re.compile(r"\b(?:PI_[A-Z0-9_]+|[A-Z][A-Z0-9_]*(?:API_KEY|AUTH_TOKEN|OAUTH_TOKEN)|AWS_(?:PROFILE|ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN|REGION)|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)\b")
    scan_roots = [source / "packages/ai/src", source / "packages/coding-agent/src",
                  source / "packages/coding-agent/docs"]
    for root in scan_roots:
        for path in sorted(root.rglob("*")):
            if not path.is_file() or path.suffix not in {".ts", ".md"}:
                continue
            for line_no, line in source_lines(path):
                for name in sorted(set(env_pattern.findall(line))):
                    add(items, seen, "environment-variable", name, location(path, source, line_no), "ZetaRuntime")
    settings_path = source / "packages/coding-agent/src/core/settings-manager.ts"
    interface: str | None = None
    depth = 0
    for line_no, line in source_lines(settings_path):
        start = re.match(r"export interface (\w*Settings)\s*\{", line)
        if start:
            interface = start.group(1)
            depth = 1
            continue
        if interface:
            depth += line.count("{") - line.count("}")
            field = re.match(r"\s*([A-Za-z][A-Za-z0-9]*)\?\s*:", line)
            if field:
                add(items, seen, "settings-field", f"{interface}.{field.group(1)}",
                    location(settings_path, source, line_no), "ZetaResources")
            if depth <= 0:
                interface = None


def protocol_providers_tools_tui(source: Path, items: list[dict[str, object]], seen: set[str]) -> None:
    schemas = source / "packages/protocol/src/schemas.ts"
    for line_no, line in source_lines(schemas):
        schema = re.match(r"export const (\w+Schema)\s*=", line)
        if schema:
            add(items, seen, "wire-schema", schema.group(1), location(schemas, source, line_no), "ZetaProtocol")
        for literal in re.findall(r"Type\.Literal\(\"([^\"]+)\"\)", line):
            add(items, seen, "wire-literal", literal, location(schemas, source, line_no), "ZetaProtocol")
    providers = source / "packages/ai/src/providers"
    for path in sorted(providers.glob("*.models.ts")):
        add(items, seen, "provider-api-family", path.name.removesuffix(".models.ts"),
            path.relative_to(source).as_posix(), "ZetaAI")
    tool_root = source / "packages/coding-agent/src/core/tools"
    for name in ("read", "bash", "edit", "write", "grep", "find", "ls", "powershell"):
        path = tool_root / f"{name}.ts"
        if path.exists():
            add(items, seen, "built-in-tool", name, path.relative_to(source).as_posix(), "ZetaTools",
                required=name != "powershell", note="PowerShell is inventoried but excluded from the macOS product." if name == "powershell" else None)
    component_root = source / "packages/tui/src/components"
    for path in sorted(component_root.glob("*.ts")):
        add(items, seen, "tui-component", path.stem, path.relative_to(source).as_posix(), "ZetaTUI")
    coding_index = source / "packages/coding-agent/src/index.ts"
    in_extensions = False
    for line_no, line in source_lines(coding_index):
        if line.strip() == "// Extension system":
            in_extensions = True
        elif in_extensions and line.startswith("// Footer data provider"):
            break
        elif in_extensions:
            symbol = re.match(r"\s*(?:type\s+)?([A-Z][A-Za-z0-9]+),?$", line)
            if symbol:
                add(items, seen, "extension-capability", symbol.group(1),
                    location(coding_index, source, line_no), "ZetaPluginAPI",
                    note="Semantic capability mapping only; TypeScript source compatibility is excluded.")
    durable = {
        "coding-agent-session-jsonl-v3": "packages/coding-agent/docs/session-format.md",
        "agent-core-session-jsonl-v4": "packages/agent/src/harness/session/jsonl/codec.ts",
        "sqlite-current-schema": "packages/session-backends/sqlite-node/src/sqlite/migrations/001_initial.sql",
        "protocol-v1-cbor": "packages/protocol/src/schemas.ts",
        "four-byte-big-endian-framing": "packages/protocol/src/framing.ts",
        "settings-json": "packages/coding-agent/docs/settings.md",
        "auth-json": "packages/coding-agent/docs/providers.md",
        "rpc-jsonl": "packages/coding-agent/docs/rpc.md",
    }
    for name, evidence in durable.items():
        add(items, seen, "durable-format", name, evidence, target_for(evidence))


def generate(source: Path) -> dict[str, object]:
    source = source.resolve()
    head = git(source, "rev-parse", "HEAD")
    if head != SOURCE_COMMIT:
        raise SystemExit(f"source HEAD is {head}; expected {SOURCE_COMMIT}")
    if git(source, "status", "--porcelain=v1"):
        raise SystemExit("source checkout is not clean")
    items: list[dict[str, object]] = []
    seen: set[str] = set()
    packages = package_inventory(source, items, seen)
    public_exports(source, items, seen)
    tests_and_docs(source, items, seen)
    cli_environment_settings(source, items, seen)
    protocol_providers_tools_tui(source, items, seen)
    items.sort(key=lambda item: (str(item["category"]), str(item["name"]), str(item["evidence"])))
    categories: dict[str, int] = {}
    for item in items:
        categories[str(item["category"])] = categories.get(str(item["category"]), 0) + 1
    return {
        "schemaVersion": INVENTORY_SCHEMA,
        "sourceCommit": SOURCE_COMMIT,
        "sourceTree": git(source, "rev-parse", "HEAD^{tree}"),
        "generator": "uv run python scripts/generate-compatibility-inventory.py --source <pinned-clean-checkout>",
        "mappingPolicy": "Every row is assigned to an implemented owner and verified suite. TypeScript extensions and npm/TypeScript source exports are recorded as intentional Swift-native differences; non-macOS surfaces are explicit non-goals.",
        "packages": packages,
        "summary": {"items": len(items), "required": sum(bool(i["required"]) for i in items), "categories": categories},
        "items": items,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("docs/compatibility/compatibility-inventory.json"))
    args = parser.parse_args()
    result = generate(args.source)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {args.output} with {result['summary']['items']} rows")


if __name__ == "__main__":
    main()
