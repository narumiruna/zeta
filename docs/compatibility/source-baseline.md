# Pi source baseline

## Pin

Zeta compatibility is pinned to Pi commit `56700d42ed65a94a80af7376adb19a9298065164` on the Pi `main` history.
The short display form is `56700d42e`.
The read-only oracle path used for this checkpoint was `/Users/narumi/workspace/pi`.
The commit tree object is `e6e63401081c8629aa9953c6c0d202a1ee5f8c02`.
The `packages` tree object is `af23479905ba764f7da09eb08a96224deee9c972`.
The `package-lock.json` blob object is `37842d14c45e87e34a19e0f79dbbed54a71cce23`.

Run the following command before using a checkout as an oracle.

```sh
test "$(git -C /path/to/pi rev-parse HEAD)" = "56700d42ed65a94a80af7376adb19a9298065164"
test -z "$(git -C /path/to/pi status --porcelain=v1)"
```

Fixture and inventory generators reject a different or dirty source checkout.
They never write to the supplied source checkout.

## Package versions and tree objects

The root private workspace manifest reports version `0.0.3`.
The product packages report version `0.84.3` unless noted below.

| Source package | Version | Git tree |
| --- | ---: | --- |
| `@earendil-works/pi-telemetry` | `0.84.3` | `ba847dfdc408197822e31ec2c62a67b664d954eb` |
| `@earendil-works/pi-ai` | `0.84.3` | `2aeca6e9bde810eeb42095f99caf1047519dafa8` |
| `@earendil-works/pi-agent-core` | `0.84.3` | `a04fc4ffe963a161aecbc63a152772918ceae8b9` |
| `@earendil-works/pi-protocol` | `0.84.3` | `401b6fe0bbd30b43cfcd0ad41f871009ed849e05` |
| `@earendil-works/pi-client` | `0.84.3` | `280c008f013f170e06abef5e34f348380b3b16ec` |
| `@earendil-works/pi-server` | `0.84.3` | `a1905cd8e6336648143e9c7fc7792d5002547d33` |
| `@earendil-works/pi-session-backend-sqlite-node` | `0.84.3` | `e636de2f5298e8d67a943c0bf0a2b51bffdec81e` |
| `@earendil-works/pi-tui` | `0.84.3` | `4e19af427f6b8527c979f26f34f66ca9564d60b0` |
| `@earendil-works/pi-coding-agent` | `0.84.3` | `bc829a453eb8159487dcceaf6aa957836cdeb54d` |
| `@earendil-works/pi-evals` | `0.84.3` | `fd22c6b514548bba32cd092dc49f62207630ff04` |

The compatibility inventory also records all workspace extension example manifests.
The sandbox extension example reports version `1.14.3`.
The other versioned extension examples report version `0.84.3`.

## Included surfaces

The required platform is macOS on arm64 and x86_64.
The primary executable is `zeta`.
The `pi` compatibility entry point must invoke the same product behavior.
Included semantic surfaces are telemetry, AI and providers, current agent behavior, current session systems, protocol, client, server, Unix transport, SQLite, TUI, coding-agent CLI and modes, deterministic evaluations, scripts, durable files, settings, authentication metadata, tools, resources, packages, exports, and extension capabilities.
Coding-agent JSONL version 3 is a current format.
Agent-core harness JSONL version 4 is a separate current format.
Remote protocol version 1 uses strict CBOR and four-byte big-endian framing.
Fresh databases matching the pinned SQLite schema are included.

The machine-readable mapping is in [compatibility-inventory.json](compatibility-inventory.json).
The inventory gate rejects `planned` rows; every required row records a verified pass or an explicit approved intentional difference.

## Explicit exclusions

Browser and Cloudflare Worker library distribution are not target products, although the source browser smoke check remains baseline evidence.
Windows, Linux, PowerShell product behavior, and non-macOS binaries are not required.
Historical databases created by an older mutable `001_initial.sql` are not migrated in place.
The future design in `packages/agent/docs/harness.md` is excluded where it differs from executable behavior at the pin.
TypeScript package import compatibility is excluded.
TypeScript extension source compatibility is excluded.
Resource-only Pi packages may remain inputs when they contain no executable TypeScript extension.

## Swift-native plugin boundary

Zeta will replace the TypeScript extension API with a versioned Swift-native plugin protocol.
Plugins will run out of process as executables.
The protocol must provide capability negotiation, cancellation, crash isolation, trust enforcement, and teardown.
Unknown versions or capabilities must be rejected before host mutation.
Legacy TypeScript extensions must receive one actionable migration diagnostic and must not execute.

## Verification record

The following commands were run against the oracle before and after disposable-checkout testing.

```sh
git -C /Users/narumi/workspace/pi rev-parse HEAD
git -C /Users/narumi/workspace/pi rev-parse 'HEAD^{tree}'
git -C /Users/narumi/workspace/pi ls-tree HEAD packages
git -C /Users/narumi/workspace/pi status --porcelain=v1
```

The reported commit and tree matched this document.
The source status was empty before and after all commands.
