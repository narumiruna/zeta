# Zeta

Zeta is a Swift-native macOS implementation of the Pi coding-agent harness.
Compatibility is pinned to Pi commit `56700d42ed65a94a80af7376adb19a9298065164`.
The package builds both `zeta` and the `pi` compatibility executable.

## Requirements

- macOS 14 or newer.
- Swift 6.2 or newer.
- Apple Silicon or Intel Mac.
- Provider credentials for live model requests.

## Build

```sh
swift build
swift test
swift run zeta --help
swift run pi --help
```

Run every repository gate with:

```sh
scripts/check-repository.sh
```

## Usage

```sh
export ANTHROPIC_API_KEY="..."
zeta --provider anthropic --model claude-sonnet-4-6
```

Print mode writes only final assistant text:

```sh
zeta -p "Summarize this repository"
```

JSON and RPC integrations use strict LF-delimited JSONL:

```sh
zeta --mode json "Inspect this repository"
zeta --mode rpc
```

The built-in tools are `read`, `write`, `edit`, and `bash`.
The optional `grep`, `find`, and `ls` tools can be selected with `--tools`.

## Compatibility

Zeta includes the generated catalog for 1,276 tool-capable models across 39 providers.
It implements Pi's streaming event model, agent loop, coding-agent JSONL v3 sessions, agent-core JSONL v4 sessions, protocol v1 framed CBOR, SQLite session storage, Unix client/server transport, terminal UI, strict RPC mode, and standalone session export.
Compatibility fixtures and the source inventory are under [`docs/compatibility`](docs/compatibility/README.md).

TypeScript extensions are detected but never executed.
Runtime extensions use the versioned, process-isolated `ZetaPluginSDK` protocol.
Resource-only Pi packages can provide skills, prompts, and themes.

## Documentation

- [User guide](docs/user/README.md)
- [Providers and authentication](docs/user/providers.md)
- [Sessions and migration](docs/user/sessions.md)
- [JSON, RPC, client, and server APIs](docs/user/integration.md)
- [Swift plugins and packages](docs/user/plugins.md)
- [Terminal UI](docs/user/tui.md)
- [Security](docs/user/security.md)
- [Development](docs/development/README.md)
- [Pinned source baseline](docs/compatibility/source-baseline.md)

## Release dry run

Release scripts build unsigned, non-publishing macOS artifacts:

```sh
scripts/build-release.sh --arch "$(uname -m)" --out /tmp/zeta-release
PREFIX=/tmp/zeta-install scripts/install.sh /tmp/zeta-release
PREFIX=/tmp/zeta-install scripts/uninstall.sh
```

Publishing, tagging, production signing, and notarization require a separate maintainer-approved process.

## License

Zeta is available under the [MIT License](LICENSE).
