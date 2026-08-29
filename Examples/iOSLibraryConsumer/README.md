# iOS library consumer

This independent Swift package verifies how an iOS application imports `ZetaAI` and `ZetaAgent`.
It uses a named local package dependency so resolution does not depend on the checkout directory name.
The example injects a synthetic or host-provided credential and defines its tool effect inside the application boundary.
Its simulator tests load the bundled model catalog and run deterministic provider, agent-event, and app-owned-tool paths without network access.
Run the owning checks from the repository root with `scripts/check-ios-libraries.sh`.
