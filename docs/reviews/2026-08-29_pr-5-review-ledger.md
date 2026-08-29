# Pull request 5 review ledger

This ledger covers the feedback submitted in review `5058042438` on pull request 5.
The target was identified as the only open pull request whose head is the current branch `narumi/feat/swift-native-pi-rewrite`.
The working tree was clean before this follow-up began.

## `3886554794`

Thread: `PRRT_kwDOUHHxZc6dZwaP`.

Concern: Receiving an SSE `[DONE]` record finalizes reducer state but does not stop the outer response-byte loop.

Initial outcome: Actionable and not yet addressed.

Final outcome: Already addressed by the current code after this follow-up.

Resolution: Record consumption now reports the terminal sentinel to the caller, which exits the outer byte loop and skips end-of-file decoder finalization.

Regression coverage: `testDoneSentinelTerminatesOpenAICompatibleStream` now places invalid stream data after `[DONE]` and requires successful completion from the sentinel.

## `3886554795`

Thread: `PRRT_kwDOUHHxZc6dZwaQ`.

Concern: A request cancelled before its transport send fails remains in `cancelledRequestIDs` because `reject` only removes pending continuations.

Initial outcome: Actionable and not yet addressed.

Final outcome: Already addressed by the current code after this follow-up.

Resolution: A definitive transport send failure now removes the request from cancelled-request tracking when cancellation already removed its pending continuation.

Regression coverage: `testCancelledRequestSendFailuresDoNotExhaustTrackingBudget` reproduces the ordering, fills the remaining tracking budget, and verifies that the connection still serves a request.

## `3886554797`

Thread: `PRRT_kwDOUHHxZc6dZwaS`.

Concern: Direct `Settings` decoding cannot read payloads encoded by the previous Zeta property spelling because the new stored property is required by synthesized `Codable`.

Initial outcome: Actionable and not yet addressed.

Final outcome: Already addressed by the current code after this follow-up.

Resolution: `Settings` now decodes `fullscreenExitOutput` when present and falls back to the previous `fullscreenExit` key while synthesized encoding continues to emit only the pinned key.

Regression coverage: `testPinnedFullscreenExitOutputKeyLoadsAndLegacyKeyMigrates` now directly decodes a complete previous-Zeta payload and verifies that re-encoding emits only `fullscreenExitOutput`.

## Same-pattern audit

The repository contains one HTTP-provider `[DONE]` handling path, one cancelled-request tracking set, and one `Settings` definition for the renamed fullscreen key.
The complete pull request diff was reviewed for equivalent instances of all three failure patterns.
No additional instances require changes.

## Verification

The focused strict-concurrency suite passed 35 tests covering all three findings.
The complete repository gate passed 326 XCTest cases and 57 Swift Testing cases against the disposable clean pinned oracle.
The complete local Address Sanitizer and Thread Sanitizer suites each passed the same 383 tests without findings.
Strict concurrency, warnings-as-errors, formatting, file-length, API compatibility, generated documentation, plugin examples, and pinned TypeScript interoperability checks passed.
The local iOS run passed all device and simulator library builds plus the external-consumer build before simulator boot status exceeded the command timeout.
The required iOS CI job remains the authoritative pending verification for the simulator consumer tests.
Review threads remain open until the verified commit is pushed.
