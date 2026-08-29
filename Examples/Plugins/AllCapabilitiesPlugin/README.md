# All-capabilities Swift plugin

This package demonstrates the version 1 SDK wire format for every declared registration kind.
Build it with `swift build -c release` from this directory.
The current Zeta CLI intentionally rejects this all-capabilities manifest because it wires tool registrations only.
Use a tool-only manifest with the CLI, or use this executable with a host that implements its non-tool registrations.
The callbacks intentionally echo deterministic data so the example can run without credentials.
