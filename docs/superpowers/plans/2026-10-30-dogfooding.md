# Tether dogfooding plan

Extend the ongoing Codex release with the user's seven dogfooding requirements.
Keep separate ownership for launch scripts, native transport, phone views and integration.

- [x] Detached stop/restart helper, fake-process tests, mini/worktree instructions.
- [x] Capture each configured shortcut's output and exit file independently of terminal rendering; bounded tail, failure push, one in-flight run per folder/command.
- [x] Protocol 26: command result sessions, shortcut catalog/run receipts, PR status/actions/receipts, chat warnings and live text. Rebuild Mac and phone.
- [x] PR CLI actions with explicit preview/confirmation, fresh branch/head checks, no force/admin merge or implicit branch push. Failure reported in initiating view.
- [x] Phone and paired Mac shortcut/results/PR controls; phone history/resume, files and dev server links using existing requests.
- [x] Codex chat for terminal session files and exclusively owned app-server chats; reporting/folder warning; explicit cross-agent review/handoff preview.
- [x] Verify package tests, detached helper, native transport initialization, Mac + phone builds; version 0.30.17/release notes.
- [ ] Rendered UI verification: isolated phone harness launches, but existing simulator migration failure yields blank screens; isolated Mac UI automation could not attach.
- [ ] Final independent integration review: backend findings resolved; final reviewer could not finish after account usage limit.

Deferred by user: remote pty streaming, separate dev bundle, persistent pty host, remote signed release.
