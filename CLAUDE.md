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

## Terminal
- The Mac app embeds libghostty through the `libghostty-spm` package
  (`GhosttyTerminal` product, pinned `from: "2.2.0"` in `Apps/project.yml`).
- Text into a pane: `paste(text:)` then `sendKey(.enter)`. A pasted `\r` is a
  character under bracketed paste, never submit. See `TerminalPane.send(prompt:)`.
- Every pty gets `TETHER_PANE_ID` and `TETHER_TOKEN` in its env
  (`TerminalLaunch`). Hooks echo them back as HTTP headers in phase 2.

## Rules
- Swift 6 language mode, strict concurrency. Keep `TetherCore` free of
  AppKit/UIKit/SwiftUI so it keeps testing on Linux CI.
- Bump `ProtocolVersion.current` whenever a type in `TetherProtocol` changes shape.
- Never scrape the terminal for state. Session state comes from hooks and
  the transcript (PLAN.md 3.2).
