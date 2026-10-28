# Mac ↔ iPhone protocol

Canonical for the companion wire format, pairing and transport. Types live in
`Sources/TetherProtocol/Messages.swift` and `PairingLink.swift`; bump
`ProtocolVersion.current` with any shape change (currently 4).

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
| `snapshot(Snapshot)` | After auth, then on every state change (coalesced 100 ms, skipped if unchanged). Full state: Mac name, projects, Claude tabs (`SessionSummary`, keyed by pane id), pending permissions. |
| `transcript(sessionId, events, reset)` | After `subscribe`: `reset: true` with history, then appends as the Mac's mirror reads new transcript records. Folded with `TranscriptModel`, same as the Mac. |
| `sendResult(paneId, outcome)` | `sent`, `queued` or `failed` for a `sendMessage`. |
| `error(message)` | Anything else worth showing in logs. |

Phone → Mac (`PhoneMessage`):

| Case | Effect |
|---|---|
| `hello`, `pair(code)`, `authenticate(token)` | See above. Anything else before auth closes the connection. |
| `subscribe(sessionId?)` | Stream that session's transcript; nil stops. One per connection. |
| `sendMessage(paneId, text)` | `AppModel.sendOrQueue`: typed now if Claude can take it, else queued (never into a permission prompt). |
| `permissionDecision(requestId, allow)` | `allow` or `deny("Denied from iPhone.")`. First answer wins across Mac and phones. |
| `startSession`, `reorderProjects`, `registerPush` | Phase 6; the Mac replies `error` for now. |

Messages from one phone are handled strictly in order (`CompanionClient.inbox`).
