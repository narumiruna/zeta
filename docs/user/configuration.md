# Configuration and tools

Global configuration is stored under `~/.pi/agent` for Pi path compatibility.
Project configuration is loaded from `.pi` only after the project is trusted.
Project values recursively override global values and arrays replace rather than concatenate.
Legacy queue, WebSocket, and retry fields are migrated during loading.
Writes use atomic replacement and an advisory process lock.

## Context and resources

Zeta loads global and ancestor `AGENTS.md` or `CLAUDE.md` files.
`AGENTS.override.md` replaces other context files in the same directory.
Skills use `SKILL.md` frontmatter with a name and description.
Prompt templates expand positional arguments.
Themes and explicit resource paths are discovered only within the selected trust boundary.

## Built-in tools

The default tools are `read`, `write`, `edit`, and `bash`.
`grep`, `find`, and `ls` are opt-in through `--tools`.
File mutation uses canonical path queues.
Edit replacements must be unique and non-overlapping in the original file.
BOM and line-ending styles are preserved.
Shell timeout and cancellation terminate the child process.
Output is limited by line and UTF-8 byte count, and full truncated shell output is written to a temporary file.

## Project trust

Project settings, packages, and executable plugins are ignored until trust is granted.
A parent trust decision applies to descendants.
Resource-only global packages do not grant project code permission.
Review all plugin and package source before trusting it.
