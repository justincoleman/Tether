# Mac ↔ iPhone protocol

Canonical for the companion wire format, pairing and transport. Types live in
`Sources/TetherProtocol/Messages.swift` and `PairingLink.swift`; bump
`ProtocolVersion.current` with any shape change (currently 23).

Clients are the iPhone app and, since 0.10.0, another Mac's Remote Macs
window (`Apps/Shared/MacConnection.swift`, shared by both). A Mac client
pairs with the link shown under the QR code instead of scanning it, sends its
computer name as `deviceName`, and never sends `registerPush` or
`registerActivity`, so it gets no pushes. The serving Mac lists it with its
phones under paired devices.

## Transport

- The Mac listens on TCP **7891** (`CompanionServer`), WebSocket over
  Network.framework, JSON text frames encoded with `WireCodec` (ISO-8601 dates).
- **Tailscale only.** The server drops any peer that is not a Tailscale
  address (100.64.0.0/10, fd7a:115c:a1e0::/48) or loopback (`Tailnet.isAllowedPeer`).
  Tailscale's WireGuard tunnel provides encryption and device identity, so
  the socket itself is plain `ws://`. This replaces the TLS + pinned
  certificate design in PLAN.md 3.5: same guarantees on a tailnet, no
  certificate handling. A LAN/Bonjour fallback would need TLS and is not built.
- The phone uses Network.framework too (no ATS exception needed for `ws://`),
  pings every 20 s, reconnects with backoff (2, 4, … 30 s), disconnects in
  the background and reconnects on foreground.
- Max frame 16 MB. Transcript resends are capped at the last 1500 events.

## Pairing

1. Settings → iPhone → Pair iPhone issues a one-time code (`CompanionAuth`):
   8 chars from an unambiguous alphabet, valid 120 s, single use, burned
   after 5 wrong guesses. Only one code is live at a time.
2. The QR encodes `tether://pair?v=1&host=<tailnet IP>&port=7891&code=<code>&name=<Mac name>`.
   The phone registers the `tether` URL scheme, so the system Camera works too.
3. Phone connects, sends `hello`, then `pair(code)`. Mac replies
   `paired(macId, macName, token)` and a snapshot. The token is 256-bit
   random hex; the phone keeps `{macId, name, host, port, token}` in the
   Keychain (after-first-unlock, this device only).
4. Later connections send `hello`, then `authenticate(token)` → `authenticated`.
5. Settings lists paired phones with last-seen and Remove. Removing sends
   `authFailed` to any live connection and closes it. Tokens are stored in
   `~/Library/Application Support/Tether/companion.json`, mode 0600.

## Handshake and versions

Both sides send `hello{protocolVersion, appVersion, deviceName}` first. On a
version mismatch the Mac replies with its own `hello` and closes; the phone
shows "Update needed" and stops retrying.

## Messages

Mac → phone (`MacMessage`):

| Case | When |
|---|---|
| `hello` | Reply to the phone's hello. |
| `paired` / `authenticated` | Auth succeeded. |
| `authFailed(reason)` | Wrong/expired code, revoked token. Connection closes; the phone stops retrying. |
| `snapshot(Snapshot)` | After auth, then on every state change (coalesced 100 ms, skipped if unchanged). Full state: Mac name, projects in sidebar order, Claude tabs in tab order (`SessionSummary`, keyed by pane id, with `preview`: the latest message on one line from `TranscriptModel.preview`, `permissionMode` from the last hook that reported one, and `status`: model, session cost and context window size from the status line), pending permissions, and `limits`: the 5-hour and weekly plan limits from the latest status line that reported them (nil for API-key accounts) and `limitsAt`, when a status line last reported them (protocol 24; nil from an older Mac). `SessionSummary.suggestion`: Claude Code's suggested next prompt for an idle tab whose chat shows on the Mac (protocol 25, see TRANSCRIPT.md). See HOOKS.md, Status line. Also resent when new transcript events change a preview. |
| `transcript(sessionId, events, reset)` | After `subscribe`: `reset: true` with history, then appends as the Mac's mirror reads new transcript records. Folded with `TranscriptModel`, same as the Mac. |
| `projectIcons([ProjectIcon])` | Every project icon (128 px PNG found by `ProjectIconFinder`), sent after auth and whenever one changes or the Mac's "show project icons" setting flips. Absent project = letter tile. Not part of `snapshot`, which is resent on every change. |
| `sendResult(paneId, outcome, requestId?)` | `sent`, `queued` or `failed` for a reply. Echoes the `sendMessage`/`sendImage` request ID; model changes use nil. |
| `startResult(requestId, paneId?, error?)` | Answer to `startSession`: the new tab's pane id, or a message to show. |
| `fileList(requestId, paths?, error?)` | Answer to `requestFileList`: the worktree's relative paths, as the Files panel lists them (`git ls-files` plus untracked, ignored files left out). |
| `fileContent(requestId, file?, error?)` | Answer to `requestFile`: a `RemoteFile`, text (start of the file), image bytes, binary or unreadable. Only paths from the Mac's own file list are served. |
| `devServers(requestId, servers?, error?)` | Answer to `requestDevServers`: listening dev servers found in the tab's folder (`DevServerInfo`: port, command). The paired Mac loads `http://<host>:<port>/`, which works only when the server listens beyond localhost. |
| `history(requestId, sessions?, error?)` | Answer to `requestHistory`: the project's past Claude sessions (`PastSessionInfo`), newest first. |
| `changes(requestId, snapshot?, error?)` | Answer to `requestChanges`: the tab's `ChangesSnapshot`, the same file list and commits as the Mac's Changes panel, against the same base branch. |
| `fileDiff(requestId, diff?, error?)` | Answer to `requestDiff`: that file's `FileDiff`, truncated like the Mac's viewer. |
| `error(message)` | Anything else worth showing in logs. |

Phone → Mac (`PhoneMessage`):

| Case | Effect |
|---|---|
| `hello`, `pair(code)`, `authenticate(token)` | See above. Anything else before auth closes the connection. |
| `subscribe(sessionId?)` | Stream that session's transcript; nil stops. One per connection. |
| `sendMessage(requestId, paneId, text)` | `AppModel.sendOrQueue`: typed now if Claude can take it, else queued (never into a permission prompt). |
| `permissionDecision(requestId, allow)` | `allow` or `deny("Denied from iPhone.")`. First answer wins across Mac and phones. |
| `startSession(requestId, projectId, branch?, prompt, permissionMode?, agent?)` | `AppModel.startSession`: a new Claude tab, launched as `claude "<prompt>"`, or a Codex tab (`codex "<prompt>"`) when `agent` is `codex`; a missing `agent` means Claude. Claude gets `--permission-mode` when given (only `default`, `acceptEdits`, `plan`, `auto`; anything else is ignored and the user's default applies). With `branch`, first a worktree on a new branch from `origin/<base>` (else `<base>`, else `HEAD`) under `~/Library/Application Support/Tether/Worktrees/<repo>/<branch-slug>` (`WorktreeCreator`). The Mac doesn't switch its own selected tab. The phone waits up to 90 s. |
| `reorderProjects(ids)` | Saves the sidebar order; the next snapshot carries it. |
| `renameProject(id, name)` | Display name only (`ProjectStore.renameProject`); the folder isn't touched. Blank names are ignored. |
| `setProjectPinned(id, pinned)` | Pin to Top or unpin (`ProjectStore.setPinned`). Pinning also makes the project Active and puts it last among the pinned. |
| `setProjectActive(id, active)` | Make Active or Move to Inactive (`ProjectStore.setActive`). Moving to Inactive unpins. |
| `closeSession(paneId)` | `AppModel.closePane`: closes the tab like its x button, ending a running turn. A branch worktree stays on disk; remove it from the Mac sidebar. |
| `setModel(paneId, model)` | `AppModel.setModel`: types `/model <model>` via `sendOrQueue` (alias or model id; anything else answers `failed`). Answered with `sendResult`. The new model shows once the status line redraws. |
| `requestFileList(requestId, paneId)` | The tab's worktree files. Answered with `fileList`. |
| `requestFile(requestId, paneId, path)` | One file from that list. Answered with `fileContent`. |
| `requestDevServers(requestId, paneId)` | Dev servers running in the tab's folder. Answered with `devServers`. |
| `requestHistory(requestId, projectId)` | The project's past sessions, as the Mac's History popover lists them. Answered with `history`. |
| `resumeSession(requestId, projectId, sessionId)` | Opens a past session in a Claude tab, or finds the tab already running it. Answered with `startResult`. |
| `requestChanges(requestId, paneId)` | The Changes snapshot for the tab's worktree (or project folder). Answered with `changes`; the phone gives up after 20 s. |
| `requestDiff(requestId, paneId, file)` | One file's diff. The Mac serves only a path that its current snapshot for that tab lists, so the phone can't read arbitrary files. Answered with `fileDiff`. |
| `sendImage(requestId, paneId, image, text)` | A JPEG or PNG (base64 in JSON, at most 12 MB; the phone sends JPEG, at most 2048 px on the long side). The Mac checks the magic bytes, saves it as `~/Library/Application Support/Tether/Uploads/iphone-<time>-<id>.<ext>` (`ImageUpload`), and sends `text` plus `Image from my iPhone: <path>` through `sendOrQueue`, so Claude reads the file. Answered with `sendResult`. Only Claude tabs. |
| `registerPush(PushRegistration)` | APNs device token, ActivityKit push-to-start token, bundle id, sandbox flag. Sent after every auth and when a token changes; stored on the paired device in `companion.json`. |
| `registerActivity(paneId, token?)` | The update token of that tab's Live Activity, or nil when it ended. |

Messages from one phone are handled strictly in order (`CompanionClient.inbox`).

## Push (APNs, no server)

Each Mac pushes straight to Apple with the user's own APNs key
(Settings → iPhone → Notifications: Team ID, Key ID, `.p8` in the Keychain).
`PushSender` signs an ES256 JWT (`APNsJWT`, cached 50 min) with CryptoKit and
POSTs over HTTP/2 to `api.sandbox.push.apple.com` for development builds or
`api.push.apple.com`, per the phone's `sandbox` flag. A 410 / `BadDeviceToken`
drops that token.

What is sent is decided by `PushPlanner` (TetherCore, tested) and shaped by
`PushPayload`:

| Event | Push |
|---|---|
| PermissionRequest | Alert, category `TETHER_PERMISSION` (Allow needs Face ID, Deny doesn't), time-sensitive. `macId`, `paneId`, `requestId` in the payload. |
| needsInput / question | Alert, category `TETHER_REPLY` (text reply), time-sensitive, collapse id `q-<pane>`. |
| needsInput / dialog | Alert: answer on the Mac. |
| working → done | Alert with the last message, category `TETHER_REPLY`, collapse id `s-<pane>`. |
| → error | Alert, collapse id `s-<pane>`. |
| idle/done → working | Live Activity `start` to the push-to-start token (`attributes-type: LiveActivityAttributes`). |
| working ↔ needsInput, new transcript output | Live Activity `update`, priority 5, at most every 10 s per tab, stale after 30 min. |
| leaves working/needsInput | Live Activity `end`, dismissed after 15 min. |

`LiveActivityAttributes` and `LiveActivityContent` live in TetherProtocol; the
phone conforms the former to `ActivityAttributes` (`Apps/PhoneShared`), so the
JSON keys are the Swift field names. Content has no `Date` fields because
ActivityKit decodes it with a default `JSONDecoder`.

The phone reports each activity's update token with `registerActivity`. When a
notification action or a token update arrives while the app is suspended,
iOS launches it in the background; `PhoneStore.perform(on:)` connects to the
Mac, sends, waits 1.5 s and disconnects. While the app is open it also updates
and ends activities itself from each snapshot (`LiveActivities.reconcile`).


## Protocol 17

`MirrorEvent.toolDetail(toolUseId:file:removed:added:at:)` carries the file a tool touched and, for
edits, the changed lines. `toolResult.summary` now holds the last six lines of the output rather than
the first. Phones on an older build cannot decode `toolDetail`; rebuild both apps together.

## Protocol 20

`ProjectSummary.pinned` and `.active`. `Snapshot.projects` is in the Mac sidebar's order: pinned projects in the
user's order, then the rest of Active by most recent use, then Inactive (`ProjectSections`, TetherCore). A project is
Inactive when unused for the Mac's "Move projects to Inactive after" days (default 3), or moved there by hand until
it's next used. Use is a prompt, a new tab, a Claude turn starting, or a transcript write under `~/.claude/projects`
(Claude Code outside Tether). `reorderProjects(ids)` now only matters for pinned projects; the phone sends just those.
`setProjectPinned` and `setProjectActive` change them from the phone or a paired Mac.

## Protocol 19

`Snapshot.theme` (`MacTheme`: `#rrggbb` background and foreground of the Mac's Ghostty config) lets the phone wear
the terminal's colors; light or dark follows from the background. `PhoneMessage.interrupt(paneId:)` stops that
tab's current turn (the Mac presses Esc). The phone's "Use Mac's Colors" switch is local (`useMacColors`).

## Protocol 18

`SessionSummary.agent` and `PermissionRequested.agent` (`AgentKind`: `claude`, `codex`; protocol 21)
say which agent a tab runs. Nil means an older Mac, which only had Claude tabs. The phone labels
Codex tabs, uses "Codex wants to …" in permission headings, and hides the Claude model menu for them.

`PermissionRequested.question` (`QuestionPrompt`) carries a multiple-choice question from Claude;
`PhoneMessage.answerQuestion(requestId:answer:)` answers it. Older phones ignore the field and show the
raw question as a permission.

The folder-trust question travels as a `PermissionRequested` with `toolName == "TrustFolder"`
(`TrustFolder.toolName`, `PermissionRequested.isFolderTrust`), answered with `permissionDecision`
(allow = Trust). No version bump: older phones show it as "Claude wants to trust this folder".

### Reply delivery

Compose drafts (text and photo) live with `MacConnection`, including when the
session view is closed. A send disables duplicate taps and clears the submitted
content only after a matching request ID receives `sent` or `queued`. Rejected
sends keep the draft. Disconnects and a 30-second receipt timeout also keep it
and show “Delivery wasn't confirmed”; they never automatically resend, since the
Mac may have accepted a message whose receipt was lost. Check the Mac before
manually retrying an unconfirmed delivery. Drafts are in memory, not saved across
an app restart. A receipt for an older request cannot clear a newer reply.

### Pairing storage failures

Pairing and removal succeed only after `companion.json` is atomically saved.
A failed pairing leaves the unexpired code usable; a failed removal leaves the
device paired and displays a retry error in Settings. Neither operation reports
success when storage fails. Device metadata updates remain best effort.
