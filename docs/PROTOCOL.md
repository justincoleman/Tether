# Mac ↔ iPhone protocol

Canonical for the companion wire format, pairing and transport. Types live in
`Sources/TetherProtocol/Messages.swift` and `PairingLink.swift`; bump
`ProtocolVersion.current` with any shape change (currently 9).

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
| `snapshot(Snapshot)` | After auth, then on every state change (coalesced 100 ms, skipped if unchanged). Full state: Mac name, projects in sidebar order, Claude tabs in tab order (`SessionSummary`, keyed by pane id, with `preview`: the latest message on one line from `TranscriptModel.preview`, and `permissionMode` from the last hook that reported one), pending permissions. Also resent when new transcript events change a preview. |
| `transcript(sessionId, events, reset)` | After `subscribe`: `reset: true` with history, then appends as the Mac's mirror reads new transcript records. Folded with `TranscriptModel`, same as the Mac. |
| `sendResult(paneId, outcome)` | `sent`, `queued` or `failed` for a `sendMessage`. |
| `startResult(requestId, paneId?, error?)` | Answer to `startSession`: the new tab's pane id, or a message to show. |
| `error(message)` | Anything else worth showing in logs. |

Phone → Mac (`PhoneMessage`):

| Case | Effect |
|---|---|
| `hello`, `pair(code)`, `authenticate(token)` | See above. Anything else before auth closes the connection. |
| `subscribe(sessionId?)` | Stream that session's transcript; nil stops. One per connection. |
| `sendMessage(paneId, text)` | `AppModel.sendOrQueue`: typed now if Claude can take it, else queued (never into a permission prompt). |
| `permissionDecision(requestId, allow)` | `allow` or `deny("Denied from iPhone.")`. First answer wins across Mac and phones. |
| `startSession(requestId, projectId, branch?, prompt, permissionMode?)` | `AppModel.startSession`: a new Claude tab, launched as `claude "<prompt>"`, with `--permission-mode` when given (only `default`, `acceptEdits`, `plan`, `auto`; anything else is ignored and the user's default applies). With `branch`, first a worktree on a new branch from `origin/<base>` (else `<base>`, else `HEAD`) under `~/Library/Application Support/Tether/Worktrees/<repo>/<branch-slug>` (`WorktreeCreator`). The Mac doesn't switch its own selected tab. The phone waits up to 90 s. |
| `reorderProjects(ids)` | Saves the sidebar order; the next snapshot carries it. |
| `renameProject(id, name)` | Display name only (`ProjectStore.renameProject`); the folder isn't touched. Blank names are ignored. |
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
