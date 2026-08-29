# Integration protocols

## JSON mode

JSON mode emits one strict LF-delimited JSON record per event.
Streaming message updates include deltas and content indices rather than cumulative partial messages.
The final message-end record is authoritative.
Consumers must assemble text, thinking, and tool-call arguments by content index.

## RPC mode

RPC framing splits on LF only.
U+2028 and U+2029 remain ordinary JSON string content.
A final unterminated record is accepted at EOF.
Commands are processed concurrently and responses can interleave with events.
Every response repeats the optional request ID and command name.
The Swift RPC type lists prompt, queue, model, thinking, retry, compaction, shell, session, export, and inspection commands.

## Remote protocol

Protocol version 1 uses four-byte unsigned big-endian payload length followed by one definite-length CBOR item.
The first client message is hello.
All schemas reject unknown properties and invalid transcript lifecycle combinations.
Snapshots are authoritative and progress events are transient.
Authentication belongs to the transport and never appears in protocol fields.

## Client and server

`ZetaClient` supports correlated requests, reconnect, shared and exclusive leases, detach reconciliation, listener isolation, and authoritative snapshot reduction.
`ZetaServer` supports handshake timeout, concurrent request dispatch, singleton live runtimes, multi-client attachment, sanitized errors, and idle disposal.
The macOS Unix transport applies path limits, mode `0600`, bounded writes, stale-socket checks, and inode-safe cleanup.
