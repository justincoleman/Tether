# P1 Reliability Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement these tasks.

**Goal:** Fix terminal lifetime across navigation, worktree review routing, and multiplying prompt retries; publish one PR.

**Architecture:** Keep every project's terminal view in a persistent stack, with inactive hosts attached at valid dimensions but unable to take focus or input. Scope reviews to a project/worktree and use one cancellable, bounded retry task per pane.

**Tech Stack:** Swift 6, SwiftUI/AppKit, existing Ghostty wrapper, Swift Testing.

## Tasks

- [x] Verify the clean baseline with `swift test --disable-index-store` in local build storage.
- [x] Add a native SwiftUI lifecycle harness that exercises project switches, Overview/remote coverage, and creation of a pane in an inactive project. Demonstrate failure before keeping all project hosts mounted. Modify RootView and TerminalTabsView; avoid project configuration changes.
- [x] Add worktree routing regression tests, then update AppModel review storage/routing and DiffViewer. Preserve drafts if no matching live session exists. Update docs/CHANGES.md.
- [x] Add retry lifecycle tests (bounded attempts, duplicate scheduling, cancellation and rescheduling), then replace recursive retries with one task per pane. Cancel it when a pane closes.
- [x] Run package tests and native lifecycle checks; build the macOS app using local build storage. Review the combined diff and fix actionable findings.
- [ ] Publish a PR against the repository default branch.

## Manual acceptance

1. Start a task from the phone in an unselected project; it must begin without selecting it on the Mac.
2. During terminal activity, switch projects, Overview, and a remote Mac. Return to the original session; it must retain its process and scrollback.
3. Add a review comment in worktree A, switch to worktree B, and verify drafts stay separate and A's comments never reach B.
4. With no matching live Claude tab, review sending must retain comments and explain the missing destination.

## Verification evidence

- Clean baseline: 274 package tests passed.
- After fixes: 285 package tests passed (11 new routing/retry tests).
- Native host lifecycle: six checks failed with selected-only mounting; all pass with persistent mounting.
- Old retry methods reproduced 480 send attempts in 20 ms with a 1 ms test delay; bounded scheduler tests pass.
- Real Ghostty harness: inactive/background-added panes launch actual shell processes; surfaces retain identity across navigation. Deferred hidden focus failed before cancellation/visibility guarding and passes afterward.
- macOS app build: successful with code signing disabled and local temporary build storage.
- Independent review: deferred-focus issue corrected; no remaining blocking findings.

Native checks: `scripts/test-terminal-lifetime.sh`; after `make mac`, run
`scripts/test-ghostty-lifetime.sh`. The latter also accepts explicit build-products
and Ghostty-header directories when using custom derived-data/package paths.
