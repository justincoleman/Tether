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
- `make release` builds, notarizes and publishes a signed release
  (`docs/RELEASING.md`); `scripts/ghosttykit.sh` switches libghostty to a
  source build in `Vendor/` (`--off` switches back).

## Terminal
- The Mac app embeds libghostty through the `libghostty-spm` package
  (`GhosttyTerminal` product, pinned `from: "2.2.0"` in `Apps/project.yml`).
- Text into a pane: `paste(text:)` then `sendKey(.enter)`. A pasted `\r` is a
  character under bracketed paste, never submit. See `TerminalPane.send(prompt:)`.
- The embedded libghostty rejects the whole config on any diagnostic. `TerminalHost`
  inlines `theme` files (`GhosttyConfig`), then drops only rejected lines, and passes
  an empty `TerminalTheme()` so the wrapper default never overrides user colors.
- `GhosttyConfig.tetherKeys` are unbound in the embedded terminal, since a
  focused surface takes a Ghostty binding before the menu bar. Add any new
  menu shortcut there.
- Splits: `PaneSplit` (TetherCore) pairs two tabs. `TerminalCard` lays every
  pane out in one stack and only changes frames; never move a surface to
  another container.
- Every pty gets `TETHER_PANE_ID` and `TETHER_TOKEN` in its env
  (`TerminalLaunch`). Hooks echo them back as HTTP headers.

## Look and feel
- Chrome colors come from `@Environment(\.theme)` (`Apps/Tether/App/Theme.swift`),
  derived by `ChromePalette` from the Ghostty config, or system colors when
  Settings → Appearance says so. Never hard-code `Color.accentColor`, `.blue`,
  `textBackgroundColor` etc. for chrome.
- The iPhone app's equivalent is `@Environment(\.phoneTheme)` (`PhoneTheme` in
  `Apps/TetherPhone/Model/MacColors.swift`), set by `.macColors(_:)` from the Mac's
  terminal colors. Shared phone pieces (status badge, mode chip, Needs-you card,
  pill buttons) live in `Apps/TetherPhone/Views/PhoneChrome.swift`. A view that needs
  the colors in its own body uses `PhoneTheme.resolved(_:)`. In a List, give a card its
  look with `.listRowBackground`; a border drawn inside the row gets clipped.

## Releases and What's New
- Bumping `MARKETING_VERSION` in `Apps/project.yml` requires a new entry at the
  top of `Apps/Tether/Resources/ReleaseNotes.json` (`ReleaseNotesTests` fails
  otherwise). The sidebar toast and the What's New window read that file; users
  see every release since the one they last opened.
- Project icons come from `ProjectIconFinder` (TetherCore, tested): `.tether/icon.png`,
  then an Xcode `AppIcon.appiconset`, then web icon locations. Never write into a
  user's project folder to create one.

## Hooks
- `docs/HOOKS.md` is canonical for the hook wiring, the state machine, and the
  permission response format. Update it with any change to
  `SessionRegistry.nextState` or `HookRouter`.
- Hooks reach Claude only through `claude --settings <hooks.json>`. Never write
  to `~/.claude/settings.json`.
- Logic belongs in `TetherCore` with tests; `Apps/Tether/Hooks/` only moves bytes.
- Codex tabs use the same hook server through `-c hooks.*` overrides (`CodexHooks`).
  Keep those arguments identical across launches: Codex trusts hooks by hash.
  Never write `~/.codex/config.toml` or pass `--dangerously-bypass-hook-trust`.

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

## Companion (iPhone)
- `docs/PROTOCOL.md` is canonical for the wire format, pairing and transport.
  Update it with any change to `TetherProtocol` messages or `CompanionHub`.
- Phones connect only over Tailscale (`Tailnet.isAllowedPeer`); never widen
  that without adding TLS.
- Push rules (`PushPlanner`) and payloads (`PushPayload`, `APNsJWT`) live in
  `TetherCore/APNs.swift` with tests. `LiveActivityAttributes`/`Content` field
  names are JSON keys pushed to installed phones: don't rename them.
- Pairing and token logic live in `TetherCore/CompanionAuth.swift` with tests;
  `Apps/Tether/Companion/` and `Apps/Shared/WebSocketChannel.swift` only move bytes.

## Rules
- Swift 6 language mode, strict concurrency. Keep `TetherCore` free of
  AppKit/UIKit/SwiftUI so it keeps testing on Linux CI.
- Bump `ProtocolVersion.current` whenever a type in `TetherProtocol` changes shape.
- Never scrape the terminal for state. Session state comes from hooks and
  the transcript (PLAN.md 3.2).
