# TypeScript baseline results

## Scope and outcome

These results were captured from a disposable clone at Pi commit `56700d42ed65a94a80af7376adb19a9298065164`.
The source repository remained untouched and the disposable checkout retained no tracked changes.
No publishing command ran.
Provider credentials were isolated and live-provider tests remained skipped.
The generated provider catalog was hydrated before the final run because the pinned repository intentionally ignores those build inputs.
The final offline build and complete non-credential test command passed.

## Environment

| Item | Value |
| --- | --- |
| Host | macOS `26.5.1` build `25F80` |
| Architecture | `arm64` |
| Node.js | `v25.4.0` |
| npm | `11.11.0` |
| Pi commit | `56700d42ed65a94a80af7376adb19a9298065164` |
| Disposable checkout | `/tmp/zeta-pi-baseline-56700d42` |
| Environment overrides | `PI_OFFLINE=1`, `NO_COLOR=1` |
| Provider credentials | Isolated by `test.sh` |

Pi declares Node.js `>=22.19.0`.
The observed Node.js version satisfies that declaration.

## Checkout and installation

```sh
rm -rf /tmp/zeta-pi-baseline-56700d42
git clone --quiet --no-hardlinks /Users/narumi/workspace/pi /tmp/zeta-pi-baseline-56700d42
git -C /tmp/zeta-pi-baseline-56700d42 checkout --quiet --detach 56700d42ed65a94a80af7376adb19a9298065164
npm --prefix /tmp/zeta-pi-baseline-56700d42 ci --ignore-scripts
```

The locked installation succeeded and reported zero vulnerabilities.
Lifecycle scripts remained disabled.

## Model-data hydration and build

The first offline build correctly reported that ignored generated model inputs were absent.
The required catalog was then hydrated in the disposable checkout and exported as JSON.

```sh
npm --prefix /tmp/zeta-pi-baseline-56700d42 run hydrate:model-data
npm --prefix /tmp/zeta-pi-baseline-56700d42 run generate:model-catalog
npm --prefix /tmp/zeta-pi-baseline-56700d42 run build:offline
```

Hydration produced 1,276 tool-capable models across 39 providers.
The generated `models.json` SHA-256 is `f1ae45a9df745bfdd7fac46a1e29f0e264eca1ec5cc28a7d0dde3f844cc1ea30`.
The final offline build passed every workspace build step.
Zeta records the source commit, count, and checksum beside its generated catalog.

## Complete deterministic test run

```sh
cd /tmp/zeta-pi-baseline-56700d42
PI_OFFLINE=1 NO_COLOR=1 ./test.sh
```

The command exited successfully.

| Surface | Test files | Tests | Result |
| --- | ---: | ---: | --- |
| Root scripts | Node runner | 5 passed | pass |
| Agent core | 23 passed | 418 passed, 1 skipped | pass |
| AI | 112 passed, 25 skipped | 956 passed, 834 skipped | pass |
| Client | 6 passed | 36 passed | pass |
| Coding agent | 240 passed, 6 skipped | 2,002 passed, 50 skipped | pass |
| Evaluations | 4 passed | 23 passed | pass |
| Protocol | 3 passed | 147 passed | pass |
| Server | 7 passed | 50 passed | pass |
| Telemetry | 2 passed | 15 passed | pass |
| TUI | Node dot reporter | all emitted cases passed | pass |
| SQLite backend | 11 passed | 87 passed | pass |

Credential-gated and external-service cases account for the recorded AI and coding-agent skips.
No deterministic test failed.
The TUI runner intentionally emits dots without a final numeric summary.

## Browser smoke

```sh
PI_OFFLINE=1 NO_COLOR=1 npm --prefix /tmp/zeta-pi-baseline-56700d42 run check:browser-smoke
```

The browser smoke bundle passed during the focused baseline and the hydrated build remained browser-compatible.

## Source integrity

```sh
git -C /Users/narumi/workspace/pi status --porcelain=v1
git -C /tmp/zeta-pi-baseline-56700d42 status --porcelain=v1
```

Both commands returned empty output after the final build, test, fixture, and interoperability runs.
The oracle stayed pinned at `56700d42ed65a94a80af7376adb19a9298065164`.

## Remaining optional live checks

Live provider smoke tests require user-controlled credentials and mutable external services.
They are not part of the deterministic release gate.
When credentials are supplied, reports must redact secrets and identify every provider or service that was unavailable.
