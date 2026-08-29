#!/usr/bin/env -S uv run python
"""Generate deterministic compatibility seed fixtures and their checksum manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sqlite3
import struct
import subprocess
import tempfile
from pathlib import Path

SOURCE_COMMIT = "56700d42ed65a94a80af7376adb19a9298065164"
SCHEMA_VERSION = 1
GENERATOR_COMMAND = "uv run python Tests/CompatibilityFixtures/generate.py --source <pinned-clean-checkout>"


def encode_json(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode()


def jsonl(values: list[object]) -> bytes:
    return b"".join(encode_json(value) for value in values)


def git(source: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(source), *args], text=True).strip()


def sqlite_fixture(path: Path, source: Path) -> None:
    migration = source / "packages/session-backends/sqlite-node/src/sqlite/migrations/001_initial.sql"
    connection = sqlite3.connect(path)
    connection.executescript(
        """
        PRAGMA page_size=4096;
        PRAGMA journal_mode=DELETE;
        PRAGMA synchronous=FULL;
        CREATE TABLE migrations (id TEXT PRIMARY KEY, applied_at TEXT NOT NULL);
        """
    )
    connection.executescript(migration.read_text(encoding="utf-8"))
    connection.execute("INSERT INTO migrations VALUES (?, ?)", ("001_initial.sql", "2023-11-14T22:13:20.000Z"))
    connection.execute(
        "INSERT INTO sessions VALUES (?, ?, ?, ?, ?)",
        ("session-fixture", 1700000000000, "/fixture/project", None, '{"name":"fixture"}'),
    )
    connection.execute("INSERT INTO session_sequences VALUES (?, ?)", ("session-fixture", 2))
    connection.execute(
        "INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?)",
        ("session-fixture", 1, "entry-1", None, "message", 1700000000001, '{"role":"user","content":"hello"}'),
    )
    connection.execute("INSERT INTO lanes VALUES (?, ?, ?, ?)", ("session-fixture", "main", "entry-1", None))
    connection.execute(
        "INSERT INTO branch_entries VALUES (?, ?, ?, ?, ?, ?)",
        ("session-fixture", "entry-1", "entry-1", 1, "message", None),
    )
    connection.execute(
        "INSERT INTO branch_tips VALUES (?, ?, ?)",
        ("session-fixture", "entry-1", "entry-1"),
    )
    connection.commit()
    connection.execute("VACUUM")
    connection.close()


def fixture_bytes() -> dict[str, bytes]:
    cbor_vectors = [
        {"name": "null", "diagnostic": "null", "hex": "f6"},
        {"name": "false", "diagnostic": "false", "hex": "f4"},
        {"name": "safe-integer", "diagnostic": "9007199254740991", "hex": "1b001fffffffffffff"},
        {"name": "text", "diagnostic": '"zeta"', "hex": "647a657461"},
        {"name": "array", "diagnostic": "[1,2,3]", "hex": "83010203"},
        {"name": "map", "diagnostic": '{"type":"hello"}', "hex": "a164747970656568656c6c6f"},
    ]
    # Pi protocol v1 client hello: {"type":"hello","version":1}.
    hello_cbor = bytes.fromhex("a264747970656568656c6c6f6776657273696f6e01")
    framed_hello = struct.pack(">I", len(hello_cbor)) + hello_cbor
    return {
        "v1/canonical-json/values.json": encode_json({
            "null": None,
            "booleans": [False, True],
            "numbers": [-0.0, 0, 1, -1, 9007199254740991],
            "strings": ["", "ASCII", "雪", "👩🏽‍💻", "line\nfeed"],
            "orderedObject": {"z": 1, "a": 2},
            "nested": {"array": [None, {"ok": True}]},
        }),
        "v1/events/agent-events.jsonl": jsonl([
            {"type": "agent_start"},
            {"type": "turn_start"},
            {"type": "message_start", "message": {"role": "assistant", "content": []}},
            {"type": "message_update", "delta": {"type": "text_delta", "delta": "hello"}},
            {"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": "hello"}]}},
            {"type": "turn_end"},
            {"type": "agent_end"},
        ]),
        "v1/rpc/transcript.jsonl": jsonl([
            {"type": "prompt", "id": "request-1", "message": "hello"},
            {"type": "response", "id": "request-1", "command": "prompt", "success": True},
            {"type": "agent_event", "event": {"type": "agent_start"}},
        ]),
        "v1/providers/requests.json": encode_json({
            "openai-chat-completions": {"model": "fixture-model", "messages": [{"role": "user", "content": "hello"}], "stream": True},
            "anthropic-messages": {"model": "fixture-model", "max_tokens": 16, "messages": [{"role": "user", "content": "hello"}]},
            "google-generative-ai": {"contents": [{"role": "user", "parts": [{"text": "hello"}]}]},
        }),
        "v1/providers/streams.jsonl": jsonl([
            {"provider": "openai", "event": "start"},
            {"provider": "openai", "event": "text_delta", "delta": "hel"},
            {"provider": "openai", "event": "text_delta", "delta": "lo"},
            {"provider": "openai", "event": "done", "stopReason": "stop"},
        ]),
        "v1/protocol/cbor-vectors.json": encode_json({"protocolVersion": 1, "vectors": cbor_vectors}),
        "v1/protocol/framed-hello.bin": framed_hello,
        "v1/sessions/coding-agent-v3.jsonl": jsonl([
            {"type": "session", "version": 3, "id": "00000000-0000-7000-8000-000000000001", "timestamp": "2023-11-14T22:13:20.000Z", "cwd": "/fixture/project"},
            {"type": "message", "id": "entry-1", "parentId": None, "timestamp": "2023-11-14T22:13:20.001Z", "message": {"role": "user", "content": "hello", "timestamp": 1700000000001}},
        ]),
        "v1/sessions/agent-core-v4.jsonl": jsonl([
            {"kind": "header", "version": 4, "id": "session-fixture", "createdAt": 1700000000000, "cwd": "/fixture/project"},
            {"kind": "entry", "lane": "main", "type": "custom", "id": "entry-1", "seq": 1, "parentId": None, "timestamp": 1700000000001, "customType": "note", "data": {"text": "hello"}},
            {"kind": "lane", "seq": 2, "lane": "main", "leafId": "entry-1"},
        ]),
        "v1/terminal/ansi-render.json": encode_json({
            "columns": 12,
            "input": "\u001b[31mred\u001b[0m 雪 👩🏽‍💻",
            "plainText": "red 雪 👩🏽‍💻",
            "expectedRows": ["red 雪 👩🏽‍💻"],
        }),
        "v1/migrations/auth-settings.json": encode_json({
            "auth": {"provider": "fixture", "credential": "<redacted-fixture>"},
            "legacySettings": {"defaultModel": "fixture/model", "showImages": False},
            "expectedSettings": {"defaultModel": "fixture/model", "terminal": {"showImages": False}},
        }),
        "v1/tools/results.json": encode_json({
            "read": {"content": "alpha\nbeta\n", "lines": 2},
            "edit": {"replacements": 1},
            "bash": {"output": "ok\n", "exitCode": 0},
            "grep": {"matches": [{"path": "fixture.txt", "line": 2, "text": "beta"}]},
            "find": ["fixture.txt"],
            "ls": ["fixture.txt"],
        }),
    }


def generate(source: Path, output: Path) -> dict[str, object]:
    source = source.resolve()
    if git(source, "rev-parse", "HEAD") != SOURCE_COMMIT:
        raise SystemExit(f"source checkout must be at {SOURCE_COMMIT}")
    if git(source, "status", "--porcelain=v1"):
        raise SystemExit("source checkout must be clean")
    version_root = output / "v1"
    if version_root.exists():
        shutil.rmtree(version_root)
    files = fixture_bytes()
    for relative, data in files.items():
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    sqlite_path = output / "v1/sqlite/current-schema.sqlite3"
    sqlite_path.parent.mkdir(parents=True, exist_ok=True)
    sqlite_fixture(sqlite_path, source)
    entries = []
    for path in sorted((output / "v1").rglob("*")):
        if path.is_file():
            data = path.read_bytes()
            entries.append({
                "path": path.relative_to(output).as_posix(),
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            })
    manifest: dict[str, object] = {
        "schemaVersion": SCHEMA_VERSION,
        "fixtureSet": "compatibility-seed-v1",
        "sourceCommit": SOURCE_COMMIT,
        "sourceTree": git(source, "rev-parse", "HEAD^{tree}"),
        "generatorCommand": GENERATOR_COMMAND,
        "oracleStatus": "Source-pinned golden vectors and durable artifacts are regenerated deterministically and exercised by Swift and TypeScript interoperability gates.",
        "files": entries,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def check(source: Path, output: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="zeta-fixtures-") as temporary:
        generated = Path(temporary) / "CompatibilityFixtures"
        generate(source, generated)
        expected = {path.relative_to(output).as_posix(): path.read_bytes() for path in output.rglob("*") if path.is_file() and path.name not in {"README.md", "generate.py"}}
        actual = {path.relative_to(generated).as_posix(): path.read_bytes() for path in generated.rglob("*") if path.is_file()}
        if expected != actual:
            missing = sorted(actual.keys() - expected.keys())
            extra = sorted(expected.keys() - actual.keys())
            changed = sorted(name for name in actual.keys() & expected.keys() if actual[name] != expected[name])
            raise SystemExit(f"fixture mismatch: missing={missing}, extra={extra}, changed={changed}")
    print(f"fixtures verified at {SOURCE_COMMIT}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        check(args.source, args.output.resolve())
    else:
        manifest = generate(args.source, args.output.resolve())
        print(f"generated {len(manifest['files'])} fixtures")


if __name__ == "__main__":
    main()
