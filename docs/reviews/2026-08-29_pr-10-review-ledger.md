# Pull request 10 review ledger

This ledger covers the feedback submitted in reviews `5058460690` and `5058517227` on pull request 10.
The target was identified from the current branch `narumi/chore/remove-github-workflows` and confirmed as `https://github.com/narumiruna/zeta/pull/10`.
The working tree was clean before this follow-up began.

## `3886940944`

Thread: `PRRT_kwDOUHHxZc6dawtF`.

Concern: The documented release environment commands print the architecture and tool versions but do not fail when they differ from the required arm64, Swift 6.2.0, and uv 0.9.26 pins.

Initial outcome: Actionable and not yet addressed.

Final outcome: Already addressed by the current code after this follow-up.

Resolution: `scripts/check-release-environment.sh` reads the Swift and uv pins from `.tool-versions`, records the environment, and fails unless the host is arm64 and the tool versions match.
The release procedure now runs that gate before tests, sanitizers, or artifact builds.

Regression coverage: `Tests/ScriptTests/test_release_environment.py` covers exact and zero-patch-shortened Swift 6.2.0 output and rejects x86_64, an unpinned Swift version, and an unpinned uv version.

## `3886995577`

Thread: `PRRT_kwDOUHHxZc6da507`.

Concern: The Swift parser accepts unpinned prerelease and extended version tokens because it keeps only their numeric prefix.

Initial outcome: Actionable and not yet addressed.

Final outcome: Already addressed by the current code after this follow-up.

Resolution: Swift validation now preserves the complete version token and permits only the exact pin or its explicit zero-patch-shortened alias.

Regression coverage: The focused script tests reject `6.2-dev` and `6.2.0.1` while retaining support for the Xcode-style `6.2` spelling of the `6.2.0` pin.

## `3886995579`

Thread: `PRRT_kwDOUHHxZc6da509`.

Concern: A pinned standalone Swift compiler can pass while the required iOS checks use a different compiler selected by Xcode.

Initial outcome: Actionable and not yet addressed.

Final outcome: Already addressed by the current code after this follow-up.

Resolution: The release environment gate now uses the same `DEVELOPER_DIR` selection as the iOS gate and separately validates `xcrun swift --version` against the Swift pin before invoking iOS checks.

Regression coverage: The focused script tests reject an Xcode Swift version that differs from the pin even when PATH Swift matches.

## `3886995581`

Thread: `PRRT_kwDOUHHxZc6da50_`.

Concern: Local release validation can build artifacts from untracked inputs that are absent from the reviewed commit and source archive.

Initial outcome: Actionable and not yet addressed.

Final outcome: Already addressed by the current code after this follow-up.

Resolution: The release environment gate and `scripts/build-source-archive.sh` now reject every non-empty `git status --porcelain --untracked-files=all` result and ignored inputs under `Sources`, `Tests`, `Examples`, or `docs`.

Regression coverage: The focused script tests verify that both entry points accept a clean checkout and reject untracked or ignored release inputs under `Sources` or `docs`.

## Same-pattern audit

The release and toolchain documentation now use the executable gate instead of print-only environment validation.
The repository has one release Swift-version parser, and it validates both PATH and Xcode output through the same exact-token comparison.
The release environment gate and source-archive builder are the two release entry points that require a clean checkout, and both now check porcelain status plus ignored release-input paths.
The release environment gate and iOS gate use the same explicit-or-default `DEVELOPER_DIR` selection.
No other current non-historical GitHub Workflow or CI policy references remain.

## Verification

The twelve focused release-environment and source-archive regressions passed.
All 18 repository script tests passed.
An earlier complete repository-gate run encountered an unrelated timeout in `ZetaPluginAPITests.testPluginRequestTimeoutIncludesBlockedStdinWrite`; its focused rerun passed.
A complete repository gate then passed on rerun against the clean pinned oracle before `main` was merged into the pull request.
After `main` was merged as `8975f05`, an earlier complete gate run passed 16 script tests, 333 XCTest cases, 57 Swift Testing cases, strict builds, API checks, plugin examples, and TypeScript interoperability.
The first final gate attempt passed all 18 script tests and continued through unrelated Swift tests until the 300-second command limit terminated it.
The final gate rerun passed all 18 script tests and 57 Swift Testing cases but reported two failures in the unchanged `LatestInteractiveFeedbackTests.testInteractiveExitCancelsAndWaitsForDirectShell` and one timeout in the unchanged `ZetaPluginAPITests.testPluginRequestTimeoutIncludesBlockedStdinWrite`.
The plugin timeout regression passed when run alone, while the interactive regression still failed its two existing assertions when rerun alone.
Documentation, file-length, secret, license, fixture, inventory, and generated-file checks passed on the merged head.
The final diff was checked for whitespace errors and equivalent release-validation patterns.
