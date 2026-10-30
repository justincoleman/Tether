# Codex chat implementation plan

**Goal:** Make Codex usable in Tether's Mac/phone conversation views and add
explicit collaboration with Claude, including native app-server chat.

**Architecture:** Existing terminal panes keep hooks and file mirrors. Native
Codex panes own a stdio RPC process and emit the existing conversation events.
Pure Foundation helpers hold parsing, transport, health, collision, and transfer
rules; app views adapt those values. No global agent settings or new libraries.

- [x] Add test-first Codex rollout parser/locator and agent-routed TranscriptFeed.
      Files: CodexTranscriptParser/Locator, TranscriptParser, MirrorStore, tests.
- [x] Add test-first RPC client with bounded framing/request lifecycle and a
      real initialize/shutdown smoke test. Files: CodexAppServer, client tests.
- [x] Add report/collision helpers and agent-aware push tests. Files:
      AgentAwareness, APNs, tests. Plumb pane reports and agent identity in app.
- [x] Persist optional native-chat/read-only pane flags with old-layout decoding
      coverage. Add native event adapter/approval tests and pane-owned driver.
- [x] Integrate startup/resume/send/stop/approvals/closure, shared chat rendering,
      phone status and native Codex start entry points. Preserve terminal paths.
- [x] Add bounded review/handoff message tests and editable preview UI. Retain
      exact worktree scope; start a fresh target tab only on explicit action.
- [x] Add Codex report and shared-folder cards; remove Claude-only chat copy.
- [ ] Complete final independent review and rendered UI verification. Backend review findings resolved; 397 package tests and both app builds pass. Reviewer usage limit and simulator migration failure block remaining checks.

Original validation scope: review the full diff, resolve findings, run package tests and both app
      builds, smoke-test app-server and inspect rendered UI. Use separate test
      scratch directories for delegated work to avoid build collisions.
- [x] Fetch latest merged default, bump the next available version (currently
      0.30.16, intended 0.30.17), add What's New, update canonical docs, verify
      both built bundle versions, and commit the complete change.

Commands: `swift test --scratch-path /tmp/tether-codex-tests --disable-index-store`;
`xcodegen generate --spec Apps/project.yml --quiet`; xcodebuild Tether and
TetherPhone with separate local derived data and the existing package cache.

Manual validation after merge: `git pull && make dev`, then rebuild TetherPhone.
Check Codex terminal-to-chat and phone content, native Codex Chat startup/send/
stop/approval, missing-hook guidance, exact-folder warnings, editable review/
handoff previews and target worktree, and What's New/bundle versions.
