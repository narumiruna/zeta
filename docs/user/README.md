# User guide

Zeta is a native macOS coding-agent executable with Pi-compatible behavior at the pinned source baseline.
Use `zeta` as the primary command or `pi` as a compatibility entry point.

## Start

Set a provider credential and run Zeta in a project directory.

```sh
export OPENAI_API_KEY="..."
zeta --provider openai --model gpt-4o-mini
```

Interactive mode provides a transcript, editor, streamed responses, tool execution, steering, and slash commands.
Print mode emits final assistant text and exits.
JSON mode emits delta-only events as JSONL.
RPC mode accepts concurrent strict JSONL commands on standard input.

## Topics

- [Providers and authentication](providers.md)
- [Configuration and tools](configuration.md)
- [Sessions and migration](sessions.md)
- [Integration protocols](integration.md)
- [Swift plugins and packages](plugins.md)
- [Terminal UI](tui.md)
- [Security](security.md)
