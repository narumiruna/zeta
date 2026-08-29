# Swift plugins and resource packages

Zeta does not execute TypeScript extensions.
A discovered TypeScript extension produces one migration diagnostic.
Use `ZetaPluginSDK` to implement executable Swift plugins.

## Isolation model

Plugins run as separate processes through protocol version 1.
The manifest declares name, version, executable, protocol version, and capabilities.
Protocol capabilities describe tools, commands, flags, events, providers, authentication, resources, sessions, and UI.
The current Zeta CLI wires tool registrations only and rejects other registration kinds at initialization with a diagnostic.
Other hosts may implement the remaining version 1 capability kinds.
Startup registration is transactional.
A failed or incompatible plugin leaves no registrations behind.
Runtime generations invalidate stale callbacks after session replacement.
The host enforces trust, bounded records, request timeouts, cancellation, teardown, and crash isolation.

## Resource packages

Npm and Git resource packages can provide skills, prompts, and themes.
Install operations use a staging directory and atomic replacement.
Npm lifecycle scripts are not executed.
Pinned package sources are not moved by bulk updates.
Project-local package mutation requires trust.

## Minimal registration

A plugin returns registrations from its initialize request and retains callback IDs for later requests.
The SDK handles LF framing, generation validation, responses, and errors.
See `Tests/ZetaPluginSDKTests` for an executable protocol example.
