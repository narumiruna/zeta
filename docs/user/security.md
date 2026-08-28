# Security

Zeta runs with the permissions of the invoking user.
It is not a filesystem, network, process, or credential sandbox.
Use a macOS sandbox, container, virtual machine, or restricted account when stronger boundaries are required.

Project trust prevents unapproved project settings, packages, and executable plugins from loading.
Trust does not make third-party code safe.
Review every package and plugin before enabling it.

Credential files use restrictive permissions and listings omit secret values.
Diagnostics and compatibility fixtures must not contain credentials, provider payload secrets, prompts, completions, or arbitrary file contents.
Secret scanning is part of the repository gate.

Protocol peers and plugin processes are untrusted.
Frame and record sizes are bounded before buffering.
Protocol schemas reject unknown fields.
Server errors sanitize internal causes.
Unix socket access relies on filesystem mode `0600` and inode-safe publication and cleanup.

Session and migration operations retain backups before replacement.
Historical unsupported SQLite schemas are rejected without writes.
Do not disclose a suspected vulnerability in a public issue.
Follow the private reporting instructions in the repository security policy.
