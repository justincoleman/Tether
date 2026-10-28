# Tether

Native macOS terminal workspace for Claude Code + iPhone companion. The plan
and architecture live in `docs/PLAN.md`; read it before changing anything
structural. Work proceeds in the numbered phases there.

## Layout
- `Package.swift`: `TetherProtocol` (wire types, Foundation only) and
  `TetherCore` (Mac-side services, no UI imports). Tests in `Tests/`.
- `Apps/project.yml`: xcodegen spec for the `Tether` (macOS) and
  `TetherPhone` (iOS) targets. The `.xcodeproj` is generated and git-ignored.
- `Apps/Tether/`, `Apps/TetherPhone/`: app sources.

## Commands
- `make bootstrap` installs xcodegen and generates the Xcode project.
- `make test` runs package tests (also works on Linux).
- `make mac`, `make phone` build the apps; `make phone-install` installs to a device.
- `make dev` runs the tests, builds the Mac app and launches it (replacing a
  running copy). `make run` skips the tests; `make run-log` runs the binary in
  the terminal to show its log output; `make stop` quits it.

## Terminal
- The Mac app embeds libghostty through the `libghostty-spm` package
  (`GhosttyTerminal` product, pinned `from: "2.2.0"` in `Apps/project.yml`).
- Text into a pane: `paste(text:)` then `sendKey(.enter)`. A pasted `\r` is a
  character under bracketed paste, never submit. See `TerminalPane.send(prompt:)`.
- Every pty gets `TETHER_PANE_ID` and `TETHER_TOKEN` in its env
  (`TerminalLaunch`). Hooks echo them back as HTTP headers.

## Hooks
- `docs/HOOKS.md` is canonical for the hook wiring, the state machine, and the
  permission response format. Update it with any change to
  `SessionRegistry.nextState` or `HookRouter`.
- Hooks reach Claude only through `claude --settings <hooks.json>`. Never write
  to `~/.claude/settings.json`.
- Logic belongs in `TetherCore` with tests; `Apps/Tether/Hooks/` only moves bytes.

## Transcript mirror
- `docs/TRANSCRIPT.md` records the transcript shapes Tether relies on. Update
  it with any parser change, and add a fixture to `TranscriptParserTests`.
- `TranscriptModel` lives in `TetherProtocol` so the phone groups steps the
  same way as the Mac.

## Changes panel
- `docs/CHANGES.md` is canonical for the base-branch rules, the git commands,
  the watcher and fetch policy, the review message format and the send gate.
- Parsers are tested against real git output; add a captured fixture when a new
  git format is parsed. All git reads go through `GitRunner`, which sets
  `GIT_OPTIONAL_LOCKS=0`. Never call git without it, or the watcher loops.
- Typing into a Claude tab goes through `AppModel.sendOrQueue`, never straight
  to `TerminalPane.send`.

## Handing work to the user for testing
- No session can compile Swift; the user builds and tests on the Mac mini.
  After every change, give the exact build command (`git pull && make dev`)
  and a numbered test list.
- Every test step that involves Claude includes the literal prompt to paste,
  in its own code block, plus what the user should see if it works. Pick
  prompts that reliably trigger the behaviour under test (e.g. a command that
  needs permission, a task long enough to interrupt).
- Note any mode the tab must be in (auto mode skips permission prompts).

## Rules
- Swift 6 language mode, strict concurrency. Keep `TetherCore` free of
  AppKit/UIKit/SwiftUI so it keeps testing on Linux CI.
- Bump `ProtocolVersion.current` whenever a type in `TetherProtocol` changes shape.
- Never scrape the terminal for state. Session state comes from hooks and
  the transcript (PLAN.md 3.2).
