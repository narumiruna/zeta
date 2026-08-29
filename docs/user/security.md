# Security

Zeta runs with the permissions of the invoking user.
It is not a filesystem, network, process, or credential sandbox.
Use a macOS sandbox, container, virtual machine, or restricted account when stronger boundaries are required.

Project trust prevents unapproved project settings, packages, and executable plugins from loading.
Trust does not make third-party code safe.
Review every package and plugin before enabling it.

Credential files use restrictive permissions and listings omit secret values.
An iOS application must inject credentials explicitly and must not treat an application bundle as a secret store.
Long-lived provider secrets shipped in a distributed application can be extracted.
Prefer a backend or provider-issued short-lived token with narrow scope, and keep credentials out of source, resources, analytics, diagnostics, and tests.
Diagnostics and compatibility fixtures must not contain credentials, provider payload secrets, prompts, completions, or arbitrary file contents.
Secret scanning is part of the repository gate.

Protocol peers and plugin processes are untrusted.
Frame and record sizes are bounded before buffering.
Protocol schemas reject unknown fields.
Server errors sanitize internal causes.
Unix socket access relies on filesystem mode `0600` and inode-safe publication and cleanup.

iOS applications own foreground and background execution policy, user-interface isolation on `MainActor`, sandbox access, and every app-owned tool effect.
Cancellation does not promise completion after application suspension.
Session and migration operations retain backups before replacement.
Historical unsupported SQLite schemas are rejected without writes.
Do not disclose a suspected vulnerability in a public issue.
Follow the private reporting instructions in the repository security policy.
