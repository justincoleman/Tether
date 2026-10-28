# Tether: build plan

A native macOS terminal workspace for Claude Code, plus an iPhone companion that
mirrors every session, pushes a notification the moment Claude needs you, and
lets you start work from your pocket. Modeled on the "Bench" workflow
(Matt Birchler, Oct 2026), rebuilt from scratch as Tether.

This document is the plan: product scope, architecture, the hard decisions and
why, a phased build order, and the risks. It is written to be executed by
Claude Code one phase at a time.

---

## 0. Target feature list (the contract)

Mac app:

1. Every project has a Claude Code session ready to go. Open the app, click a
   project, the terminal is already sitting at a `claude` prompt in that repo.
2. One-click SSH into a headless Mac mini for long iOS builds and test runs.
3. Diffs appear as soon as the worktree diverges from origin: a live "Changes"
   panel showing files against `origin/<base>` plus the commit list.
4. Highlight part of a file in the diff viewer and tell Claude to change exactly
   that.
5. Sidebar status animation per project: pulsing/sparkle while working, green
   when done, blue when Claude needs input.
6. Fast and fully native. AppKit + SwiftUI, Metal-rendered terminal via
   libghostty, no web views.

iPhone app:

7. Pairs with a Mac by scanning a QR code. Pairs with several Macs.
8. Mirrors every session as a chat: Claude's messages, your messages, tool
   calls collapsed into "N steps" rows, token/context meter, branch name.
9. Push notification when Claude asks a question or needs a permission
   decision; approve or deny from the phone (and from the lock screen).
10. Start a new task or reply to a running session from the phone. Replies
    queue until the current step finishes.
11. Live Activity on the lock screen / Dynamic Island while a task runs.

Non-goals for v1: Windows/Linux, Codex/Gemini agents, multi-user, cloud sync,
App Store distribution (notarized direct download is fine).

---

## 1. Architecture overview

```
┌─────────────────────────── Mac (one per machine) ───────────────────────────┐
│                                                                             │
│  Tether.app (AppKit + SwiftUI, Swift 6)                                     │
│  ┌──────────┐  ┌───────────────┐  ┌──────────────┐  ┌────────────────────┐ │
│  │ Sidebar  │  │ Terminal tabs │  │ Changes panel│  │ Session mirror UI  │ │
│  │ projects │  │ libghostty    │  │ git watcher  │  │ (native chat view) │ │
│  └────┬─────┘  └──────┬────────┘  └──────┬───────┘  └─────────┬──────────┘ │
│       │               │ pty              │ git               │             │
│  ┌────┴───────────────┴──────────────────┴───────────────────┴──────────┐  │
│  │                      Core (Swift package, no UI)                      │  │
│  │  ProjectStore · SessionRegistry · HookServer · TranscriptTailer       │  │
│  │  GitWatcher · PairingService · CompanionServer · PushSender (APNs)    │  │
│  └───────────┬──────────────────────────────┬───────────────────────────┘  │
│              │ http://127.0.0.1:<port>      │ wss://<tailscale-ip>:<port>   │
│   claude CLI hooks (HTTP) + ~/.claude/projects/**/*.jsonl                   │
└──────────────┼──────────────────────────────┼───────────────────────────────┘
               │                              │ Tailscale (WireGuard) only
               │                       ┌──────┴────────┐        ┌──────────┐
               │                       │ iPhone app    │◄──APNs─┤ Apple    │
               │                       │ SwiftUI       │        │ (direct  │
               │                       │ multi-Mac     │        │ from Mac)│
               │                       └───────────────┘        └──────────┘
```

Three load-bearing decisions, each explained in section 3:

- The terminal runs the real interactive `claude` TUI. Structured session data
  comes from Claude Code hooks (HTTP, to a localhost server inside Tether) plus
  tailing the session transcript JSONL. Tether never re-implements the agent.
- Phone and Mac talk directly over Tailscale. There is no relay server. Push
  notifications are sent by the Mac straight to APNs with a token-based key
  stored in the Mac's Keychain.
- Everything that touches state lives in a UI-free `TetherCore` Swift package
  so the Mac app, the iPhone app, and tests share models and the wire protocol.

---

## 2. Repository layout

```
Tether/
├── Package.swift                 # TetherCore + TetherProtocol (shared)
├── Sources/
│   ├── TetherProtocol/           # Codable wire types, protocol version
│   ├── TetherCore/               # Mac-side services (no AppKit imports)
│   └── TetherCoreTests/
├── Apps/
│   ├── Tether/                   # macOS app target (Xcode project)
│   │   ├── App/                  # AppDelegate, menus, windows
│   │   ├── Sidebar/
│   │   ├── Terminal/             # libghostty host views
│   │   ├── Changes/              # diff viewer
│   │   ├── Mirror/               # native chat view of a session
│   │   └── Settings/
│   └── TetherPhone/              # iOS app target
│       ├── App/
│       ├── Pairing/
│       ├── Sessions/
│       ├── Notifications/        # UNNotification categories, NSE
│       └── LiveActivity/         # ActivityKit widget extension
├── scripts/
│   ├── bootstrap.sh              # fetch libghostty-spm, generate xcodeproj
│   ├── ghosttykit.sh             # (phase 7) build GhosttyKit.xcframework from source
│   └── phone-install.sh          # build + install to a connected iPhone
├── docs/
│   ├── PLAN.md                   # this file
│   ├── PROTOCOL.md               # companion wire protocol (phase 5)
│   └── HOOKS.md                  # hook payloads Tether consumes (phase 2)
├── Makefile                      # make mac, make phone-install, make test
└── .bench/ → .tether/            # per-project icon override convention
```

Tooling: Xcode 26 / Swift 6.2, strict concurrency, `xcodegen` or Tuist to
keep the project file generated from YAML (easier for Claude Code to edit).
Deployment targets: macOS 26, iOS 26 (Live Activity push-to-start and the
newer reorder APIs want recent OS versions; nobody else installs this).

---

## 3. The hard decisions

### 3.1 Terminal: libghostty, consumed how?

Use `libghostty-spm` (Lakr233) in phase 1. It ships a prebuilt
`GhosttyKit.xcframework` plus a `GhosttyTerminal` Swift wrapper
(`TerminalController`, `TerminalView`, `sendKey`, `paste(text:)`,
`performBindingAction`). It honors `~/.config/ghostty/config`, so your Ghostty
theme/font carry over for free. Pin `>= 1.5.2`.

Why not build libghostty ourselves on day one: the upstream API is still
untagged and "in flux". A prebuilt wrapper lets the app exist in week one.
Phase 7 adds `scripts/ghosttykit.sh` that builds from the ghostty repo with
Zig 0.16 so we can track upstream and drop the dependency if it stalls.

What we need from the terminal layer, and the wrapper provides:

- Spawn a pty with a given cwd, env, and command (`.exec` backend).
- Write text to the pty programmatically (phone replies, "ask Claude about
  this selection", pairing-free SSH launch).
- Child-exited callback (session ended → sidebar idle).
- Title/cwd change callbacks (OSC 7 / OSC 0).
- Scrollback and the standard Ghostty keybindings.

Risk: the wrapper's `.exec` backend may not expose a "write to stdin"
primitive distinct from `paste(text:)`. Paste is fine for prompts (Claude Code
handles bracketed paste) but we must append a bare `\r` for submit. Verify in
phase 1 spike before anything else is built on it.

### 3.2 Where session state comes from

Two sources, both read-only with respect to the agent:

**A. Claude Code hooks, HTTP type.** Tether runs a tiny HTTP server on
`127.0.0.1:<random port>`. On first launch it merges a hook block into
`~/.claude/settings.json` (idempotent, namespaced under a `tether` comment key
pattern so we can remove it cleanly):

```json
{
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:PORT/hook",
                           "headers": { "X-Tether-Pane": "$TETHER_PANE_ID", "X-Tether-Token": "$TETHER_TOKEN" },
                           "allowedEnvVars": ["TETHER_PANE_ID", "TETHER_TOKEN"], "timeout": 5, "async": true }]}],
    "UserPromptSubmit":  [ ...same... ],
    "Stop":              [ ...same... ],
    "StopFailure":       [ ...same... ],
    "Notification":      [ ...same... ],
    "SessionEnd":        [ ...same... ],
    "PostToolUse":       [ ...same, async... ],
    "PermissionRequest": [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:PORT/permission",
                           "headers": { ... }, "allowedEnvVars": [...], "timeout": 600 }]}]
  }
}
```

The two env vars are injected into every pty Tether spawns. Because HTTP hook
headers can interpolate allow-listed env vars, each hook arrives already
stamped with the pane it belongs to. That is the whole session-to-tab mapping
problem solved without parsing process trees. `session_id`, `cwd`, and
`transcript_path` arrive in the body.

The port is random per launch, so Tether rewrites the hook URLs on every
launch. If the settings file is unwritable or the user declines, Tether falls
back to source B only and the sidebar still works (degraded: no permission
relay).

State machine driven by hooks:

| Hook | Sidebar state |
| --- | --- |
| `SessionStart` | idle (session attached to pane) |
| `UserPromptSubmit` | working |
| `PermissionRequest`, `Notification{permission_prompt, idle_prompt, agent_needs_input, elicitation_*}` | needs input (blue) |
| `Stop` | done (green) until the tab is focused, then idle |
| `StopFailure` | error (red) |
| `SessionEnd`, pty child exit | idle / detached |

**B. Transcript tailing.** `transcript_path` points at
`~/.claude/projects/<encoded cwd>/<session_id>.jsonl`. Tether tails it with a
`DispatchSource` file watcher and parses each line into `MirrorEvent`s
(assistant text, user text, tool_use, tool_result, usage). This is what the
phone chat view and the Mac's native mirror view render. Hooks give us edges
(start/stop/needs input) with low latency; the transcript gives us content.
Neither needs the TUI to be scraped.

The JSONL format is not a public contract. Parser must be tolerant: unknown
record types are skipped, never fatal, and the parser has fixture tests against
real transcripts captured from the installed CLI version. Tether shows the
Claude Code version it was last verified against in Settings.

Context meter ("174k of 200k" in the reference): read `usage` from the last
assistant record in the transcript. Good enough.

### 3.3 Permission prompts from the phone

The `PermissionRequest` hook can return a decision. Flow:

1. Claude Code calls `/permission` and blocks (hook timeout set to 600 s).
2. Tether shows a native prompt in the Mac UI, marks the sidebar blue, and
   pushes the request to every paired phone (APNs alert with Allow/Deny
   actions, plus the live WebSocket if connected).
3. First answer wins: Mac click, phone action, or lock-screen action. Tether
   responds to the hook with `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
   or `deny` with a reason.
4. Mac UI also offers "Ask in terminal", which returns an empty 200 so the
   normal TUI prompt appears. Hook timeout expiring does the same.

This means the TUI prompt is *replaced* by Tether's prompt while Tether is
running, not duplicated. That is a deliberate tradeoff: it is the only way to
make the phone answer authoritative without injecting keystrokes into the
terminal, which is fragile and races with the user. Tether's Mac prompt must
therefore show the same information the TUI would: tool name, the command or
diff, and the "allow this session" option (map to `allow` + `updatedPermissions`
if the hook output supports it in the installed version; otherwise just allow once).

`idle_prompt` / `agent_needs_input` (Claude asked a question in text) is not a
permission; it is a reply. The phone shows the question and a compose box.
Replies are delivered via 3.4.

### 3.4 Sending text into a session from the phone

Phone → Mac: `SendMessage{sessionId, text}` over the WebSocket.
Mac: if the session state is `needs input` or `idle`, paste `text + "\r"`
into that pane's pty. If the state is `working`, queue it and show "Your
message waits for the current step to finish" on both devices; flush on the
next `Stop` or `Notification` hook. Queue is per session, persisted so a Mac
restart does not lose it.

Starting a brand-new task from the phone: `StartSession{projectId, branch?,
prompt}` → Mac opens a new tab (optionally on a fresh worktree, see 3.6),
spawns `claude "<prompt>"` with the env vars set. The phone sees the new
session appear via the normal snapshot stream.

### 3.5 Mac ↔ phone transport and pairing

Transport: TLS WebSocket, Mac is the server, bound to the Mac's Tailscale IP
(looked up via `tailscale ip -4` or the Tailscale local API; fall back to
Bonjour on the LAN for the no-Tailscale case). No relay. The Mac mini is
always on the tailnet, so the phone reaches it from anywhere.

Pairing (QR):

1. Mac generates an Ed25519 identity keypair once (Keychain). For each pairing
   it generates a one-time code valid for 2 minutes.
2. QR payload: `tether://pair?v=1&host=<tailnet ip or MagicDNS name>&port=&fp=<identity pubkey fingerprint>&code=<one-time>&name=<Mac name>`.
3. Phone connects, verifies the server cert against `fp` (self-signed cert
   bound to the identity key), presents `code`, receives a long-lived bearer
   token scoped to that phone. Phone stores `{macId, name, host, fp, token}`.
4. Mac shows paired phones in Settings with revoke.

Multi-Mac: the phone keeps a list of paired Macs and holds one WebSocket per
reachable Mac. The Overview screen merges sessions across Macs, tagged with the
Mac name. Each Mac is independent; nothing is shared between Macs.

Protocol: `TetherProtocol` package, versioned with an integer. Every
connection starts with `Hello{protocolVersion, appVersion}`. Mismatch shows an
"Update needed" banner on the older side (visible in the reference video) and
the connection stays up in read-only mode where possible.

Messages (sketch; full spec lands in `docs/PROTOCOL.md`):

- Mac → phone: `Hello`, `Snapshot{projects, sessions}` (full state on connect),
  `SessionEvent{sessionId, MirrorEvent}`, `SessionState{sessionId, state}`,
  `PermissionRequested{requestId, sessionId, tool, summary, detail}`,
  `PermissionResolved{requestId, by}`, `ChangesUpdated{projectId, summary}`,
  `FileDiff{...}` (on demand).
- Phone → Mac: `Hello`, `SendMessage`, `StartSession`, `PermissionDecision{requestId, allow}`,
  `RequestDiff{projectId, path}`, `ReorderProjects{ids}`, `RegisterPush{deviceToken, liveActivityPushToStartToken}`.

### 3.6 Notifications and Live Activities without a server

The Mac sends APNs pushes directly: token-based auth (`.p8` key, key ID, team
ID) using an ES256 JWT, HTTP/2 to `api.push.apple.com`. The key lives in the
Mac Keychain, entered once in Settings. Each Mac holds its own copy; that is
fine for a personal tool. This removes the one piece of infrastructure a
companion app normally needs.

Pushes sent:

- `permission_request`: alert, category with Allow/Deny actions, `interruption-level: time-sensitive`. Actions post `PermissionDecision` to the Mac from a background task; if the Mac is unreachable the phone opens the app.
- `needs_input`: alert with a text-input action ("Reply") so you can answer from the lock screen.
- `done` / `error`: alert, collapsed per session with `apns-collapse-id`.
- Live Activity: `start` via push-to-start token when a session enters `working`; `update` on each step; `end` on `Stop`. One activity per session, capped at a few concurrent to respect ActivityKit budgets.

Phone-side the app can also raise local notifications when the WebSocket is
live and the app is foregrounded, so nothing depends on APNs while you are
looking at it.

### 3.7 Projects, sessions, worktrees

Model:

```
Project { id, name, path, icon, baseBranch, order, remoteHost? }
Worktree { id, projectId, path, branch, isPrimary }
Session { id (claude session_id), worktreeId, paneId, state, startedAt, lastEventAt, usage }
```

- Adding a project = picking a folder. Icon resolution: `.tether/icon.png`,
  then an Xcode `AppIcon` asset, then a web favicon/logo in the repo, then the
  initial letter. "Ask Claude to set icon" is a canned prompt into the session.
- "Every project has a session ready": on app launch (and on project add),
  Tether opens a tab per project and runs `claude --resume <last session id>`
  if one exists for that worktree, else `claude`. Launch is lazy and
  staggered (one every 300 ms) so twelve projects do not all spawn at once.
- "New Agent on a Branch": `git worktree add ../<repo>-<branch> -b <branch>`
  under a Tether-managed directory, new tab, new session. Worktrees nest under
  their project in the sidebar. Finishing: Tether offers "remove worktree"
  once the branch is merged (detected by the git watcher).
- Reorder projects by drag (Mac) or long-press drag (phone); order is stored
  by the Mac and broadcast in the next snapshot.

### 3.8 Changes panel (diffs against origin)

`GitWatcher` per worktree:

- FSEvents on the worktree (debounced 300 ms, ignoring `.git/index.lock`
  churn) triggers `git status --porcelain=v2` and `git diff --numstat
  origin/<base>...HEAD` plus working tree.
- `git fetch origin <base>` on a timer (every 2 min while the project is
  visible, otherwise 10 min) and immediately after a `Stop` hook, so a PR
  merged by Claude shows up without a click.
- Panel shows: branch vs upstream, "Against origin/main" file list with
  +/- counts, commit list, and a per-file unified diff rendered natively
  (attributed strings, syntax highlighting via a lightweight tokenizer; no
  web view).

Shell out to `git` rather than linking libgit2. Correctness on worktrees,
sparse checkouts, and credential helpers is not worth re-deriving.

### 3.9 "Change this specific thing"

In the diff/file viewer: select lines → an inline comment box appears
("What should Claude change here?"). Submit composes:

```
In `path/to/file.swift` lines 28–33:

<selected text>

<your instruction>
```

and pastes it into that worktree's session (queued if working). Multiple
pending comments can be collected and sent as one message, like a code
review. This is a thin feature on top of 3.4 and 3.8; do it after both.

### 3.10 One-click SSH to the Mac mini

Settings → Remote hosts: `{name, host, user}`. Toolbar "+" offers "ssh
<name>" which opens a terminal tab running `ssh -t user@host` with the pty's
cwd set to `~`. Tailscale SSH or key auth makes it passwordless. A project may
also declare `remoteHost`, in which case its session tab runs
`ssh -t host 'cd <path> && claude'` instead of a local `claude`.

Caveat, stated plainly: hooks from a `claude` running on the mini report to
the *mini's* Tether, not the laptop's. The phone sees mini sessions because it
pairs with the mini directly. The laptop does not mirror mini sessions in v1.
Mac-to-Mac federation is a possible v2; it is not needed for the stated
workflow (phone sees everything, laptop runs its own projects, mini runs the
long builds).

### 3.11 Sidebar status animation

A single `StatusBadge` SwiftUI view driven by `Session.state`:

- `working`: three-sparkle drift animation (TimelineView at 20 fps, pauses when
  the window is occluded).
- `needsInput`: solid blue dot with a slow pulse and the project row tinted.
- `done`: green check, row tinted green; clears to `idle` when the tab gains focus.
- `error`: red dot; clicking opens the session.
- `idle`: nothing.

The Overview row counts projects in `needsInput`. App icon badge mirrors it.
Dock icon bounces once on `needsInput` when the app is not frontmost.

---

## 4. Phased build order

Each phase ends in something you can use. Estimates assume Claude Code is
doing most of the typing with you reviewing.

### Phase 0: Skeleton (half a day)
- Repo layout above, `Package.swift` with `TetherProtocol` + `TetherCore`,
  xcodegen spec for both apps, `make mac` builds an empty window, `make test`.
- CI: GitHub Actions `macos-26` runner running `swift test` and `xcodebuild`
  for both targets (no signing).

### Phase 1: Terminal workspace (2–3 days)
- Integrate `libghostty-spm`. Sidebar with projects, tabs per project, split
  support deferred.
- Spawn `claude` per project with `TETHER_PANE_ID` / `TETHER_TOKEN` in env.
- Spike and *verify*: programmatic write to pty works for a paste + `\r`,
  child-exit callback fires, Ghostty config applies.
- Persist layout (`~/Library/Application Support/Tether/state.json`).
- SSH tabs (3.10, local part only).
- Exit criterion: you can do a day's work in it with no status features.

### Phase 2: Hooks and sidebar state (1–2 days)
- `HookServer` on localhost, settings.json merge/unmerge, per-launch port rewrite.
- State machine from 3.2 and the status badge from 3.11.
- `docs/HOOKS.md` with captured payloads for the installed CLI version.
- Native `PermissionRequest` prompt on the Mac (3.3, Mac half) including
  "Ask in terminal" fallback.
- Exit criterion: sidebar reliably turns blue/green while you work in the TUI.

### Phase 3: Transcript mirror (2 days)
- `TranscriptTailer` + tolerant JSONL parser with fixture tests.
- Mac-side native mirror view (chat rendering, collapsed tool steps, context
  meter). This is the same view the phone will show, so build it once in
  SwiftUI inside a shared target where possible.
- Exit criterion: open a session's mirror view beside the terminal and it
  stays in sync.

### Phase 4: Changes panel + highlight-to-ask (2–3 days)
- `GitWatcher`, Changes panel, diff viewer, fetch timers (3.8).
- Selection → comment → paste into session (3.9), with queueing (3.4 queue
  logic, Mac-local for now).
- Exit criterion: PR merged by Claude shows as "No changes" within a minute,
  and you can send a line-range instruction without typing a path.

### Phase 5: Companion protocol + pairing (3 days)
- `TetherProtocol` messages, `docs/PROTOCOL.md`, version handshake.
- `CompanionServer` (TLS WebSocket on tailnet IP, Bonjour fallback), identity
  key, QR pairing, token store, revoke.
- iPhone app: pairing screen, Overview (multi-Mac), session list, session chat
  view reusing phase 3 rendering, compose box, permission Allow/Deny sheet.
- Exit criterion: phone shows a live session over Tailscale from off-Wi-Fi.

### Phase 6: Push, Live Activities, phone-initiated work (2–3 days)
- `PushSender` (APNs token auth, Keychain-stored key), notification categories
  with Allow/Deny and Reply actions, Notification Service Extension for
  decrypt/format, background `PermissionDecision` delivery.
- ActivityKit widget + push-to-start registration.
- `StartSession` from phone, worktree option, project reorder sync.
- Exit criterion: lock the phone, start a 20-minute job from it, get the
  permission prompt on the lock screen, answer it, see it finish.

### Phase 7: Hardening and ownership (ongoing)
- Build libghostty from source (`scripts/ghosttykit.sh`), swap in behind a
  feature flag, drop the SPM dependency once stable.
- Split panes, tab drag reordering, keyboard shortcuts (⌘1–9 projects).
- Sparkle-style updater from a GitHub release, notarized build script.
- Crash-safe state: sessions resumed after a Tether crash via `--resume`.
- Energy: throttle FSEvents and transcript tailing when on battery and
  backgrounded.

---

## 5. Risks and how the plan handles them

| Risk | Mitigation |
| --- | --- |
| libghostty API churn breaks the wrapper | Pin SPM version; phase 7 own build; terminal host code isolated in `Apps/Tether/Terminal` behind a small protocol so a swap is local. |
| Transcript JSONL format changes with a Claude Code release | Tolerant parser, fixtures per CLI version, hooks remain the source of truth for *state* so the sidebar and notifications keep working even if the chat mirror degrades. |
| Hook settings merge clobbers the user's own hooks | Merge by appending Tether's handler objects, never replacing arrays; unmerge removes only objects whose URL host is `127.0.0.1` and path starts with `/tether`. Back up settings.json before first write. |
| `PermissionRequest` hook hides the TUI prompt while Tether is down | Tether removes its hooks on clean quit; on a crash the hook URL is dead so Claude Code treats it as non-blocking error and the TUI prompts normally (`onFailure` left at `continue`). |
| Phone answers a permission after the Mac did | `requestId` + first-writer-wins; late answers get `PermissionResolved{by}` and the phone shows who answered. |
| APNs key on the Mac | Keychain, never in state.json; Settings shows only key ID. Acceptable for a single-user tool. |
| Tailscale not running | Bonjour fallback on LAN; clear "Mac unreachable" state on the phone rather than a spinner. |
| Twelve `claude` processes at launch | Lazy, staggered spawn; option to mark projects "manual start". |

---

## 6. Open questions to settle during phase 1

1. Answered in phase 1 by reading the wrapper source: `TerminalSurfaceOptions`
   takes `command`, `workingDirectory`, `envVars` and `waitAfterCommand`, and
   input has two paths, `paste(text:)` for text and `sendKey(.enter)` for
   submit. Still to confirm on a real Mac: that Claude Code submits on that
   Enter after a bracketed paste.
2. Does the installed Claude Code version's `PermissionRequest` hook output
   support "allow for session" (`updatedPermissions`)? If not, Tether's prompt
   offers allow-once only and says so.
3. Transcript record shapes for subagents and compaction: capture fixtures
   early so the parser is tested against reality, not memory.
4. Whether to ship the Mac mirror view at all or keep it phone-only. Plan
   assumes yes because it costs little once the phone needs it.

---

## 7. References

- libghostty (upstream): https://github.com/ghostty-org/ghostty
- libghostty-spm (prebuilt XCFramework + Swift wrapper): https://github.com/Lakr233/libghostty-spm
- Zig + SwiftUI embedding notes (Mitchell Hashimoto): https://mitchellh.com/writing/zig-and-swiftui
- Claude Code hooks reference (HTTP hooks, event list, env var header interpolation): https://code.claude.com/docs/en/hooks
- Workbench, a comparable AppKit + libghostty workspace, useful for prior art: https://github.com/romanmt/workbench
- Bench app page (reference product): https://github.com/mattbirchler/birchtree-productions/pull/18
- Reference video: https://www.youtube.com/watch?v=PKlJqAvzFMk
