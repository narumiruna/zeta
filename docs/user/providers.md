# Providers and authentication

The bundled model catalog is generated from the pinned Pi model generator.
It currently contains 1,276 models across 39 providers.
Run `zeta --list-models` or `zeta --list-models=search` to inspect it.

## API keys

Explicit `--api-key` values take precedence over stored or environment credentials.
Provider environment variables follow Pi names such as `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENROUTER_API_KEY`, and `AWS_ACCESS_KEY_ID`.
Credential files are created with mode `0600` in a mode `0700` directory.
Secret values are never included in credential listings or diagnostics.

## OAuth

The Swift authentication module implements PKCE, local callback, device polling, serialized refresh, and cancellation primitives.
Subscription-provider login flows must use the provider's documented authorization endpoint and preserve refresh credentials.
Concurrent refreshes for one provider share one operation.

## Google Vertex

Vertex accepts `GOOGLE_CLOUD_API_KEY` or Application Default Credentials.
Set `GOOGLE_APPLICATION_CREDENTIALS` to a credential JSON file when the default gcloud file is not suitable.
Set project and location through the same environment variables used by Pi.

## Amazon Bedrock

Bedrock supports SigV4 credentials from `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optional `AWS_SESSION_TOKEN`.
The Bedrock adapter validates AWS event-stream framing and CRC values.
Bearer-only Bedrock environments may use `AWS_BEARER_TOKEN_BEDROCK` where the provider endpoint permits it.

## Offline operation

Pass `--offline` or set `PI_OFFLINE=1` to disable startup refresh operations.
The bundled catalog remains available without network access.
Live model requests still require an available endpoint and credential.
