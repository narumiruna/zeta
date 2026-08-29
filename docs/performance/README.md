# Performance baselines

These baselines compare a release build of Zeta on macOS arm64 with the pinned TypeScript oracle at commit `56700d42e`.
The benchmark inputs are deterministic and require no provider credentials.
Results are diagnostic budgets rather than claims that unlike runtime representations have identical cost.

## Commands

```sh
swift run -c release zeta-benchmarks > docs/performance/baseline-arm64.json
node /tmp/zeta-ts-benchmark.mjs > docs/performance/baseline-typescript.json
swift build -c release --product zeta
uv run python scripts/benchmark-startup.py --binary "$(swift build -c release --show-bin-path)/zeta" --output docs/performance/startup-arm64.json
```

The temporary TypeScript benchmark imports the pinned built protocol and TUI packages and parses the generated model catalog.
Its source and exact method are recorded in implementation history and the baseline JSON remains checked in.

## Release budgets

| Workload | Iterations | Zeta arm64 budget |
| --- | ---: | ---: |
| Ordered strict JSON round trip | 1,000 | 100 ms |
| CBOR decode | 1,000 | 15 ms |
| Terminal wrapping and width | 1,000 | 350 ms |
| Typed model catalog load | 10 | 400 ms |
| Plugin envelope encode | 10,000 | 150 ms |
| Provider event reduction | 1,000 | 15 ms |
| Search 1,000 documents | 10 | 30 ms |
| SQLite append with lease and cache | 100 | 200 ms |
| Warm `zeta --help` startup median | 20 | 50 ms |

A release check fails only after the same workload exceeds its budget in three consecutive isolated runs.
The first cold startup may include operating-system code-signature and page-cache work and is recorded separately from the warm median.
Architecture-specific release validation retains benchmark output so regressions can be investigated rather than hidden.

## Interpretation

Strict ordered JSON is intentionally slower than native JavaScript JSON because it preserves number spelling, insertion order, duplicate-key rejection, and validation bounds.
Typed model-catalog loading is intentionally slower than plain JSON parsing because it validates and constructs every model URL and capability value.
CBOR and terminal wrapping are within the pinned TypeScript baseline range.
SQLite timing includes a FULL-synchronous transaction, writer-fence renewal, shared sequence allocation, statistics, and branch-cache maintenance.
Provider event timing covers normalized partial-message mutation and event creation.
Plugin envelope timing measures IPC serialization overhead, while process scheduling is covered by plugin integration tests.

## Files

- `baseline-arm64.json` contains the current Zeta release measurements.
- `baseline-typescript.json` contains the pinned TypeScript measurements.
- `startup-arm64.json` contains cold and warm startup samples.

No unexplained release-budget regression is accepted.
