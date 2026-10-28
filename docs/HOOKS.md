# Claude Code hooks in Tether

How Tether learns what each Claude session is doing, and how it answers
permission prompts. Source: `Sources/TetherCore/{HookSettings,HookRouter,
SessionRegistry,PermissionBroker}.swift`, `Apps/Tether/Hooks/`.

## Wiring

1. At launch Tether binds an HTTP server to `127.0.0.1` on a random port.
2. It writes `~/Library/Application Support/Tether/hooks.json` with HTTP hooks
   pointing at that port.
3. Every Claude pane runs `claude --settings <that file> [--resume <id>]`.

Hooks therefore apply only to sessions Tether launched. `~/.claude/settings.json`
is never modified. A `claude` you type by hand inside a Tether shell tab is not
tracked.

Settings list keys merge across sources, so your own hooks keep running
alongside Tether's.

**Verifying it works.** Do not use the `/hooks` menu for this: as of Claude
Code 2.1.308 it lists `[User]` and `[Plugin]` hooks but not hooks passed with
`--settings`, even though they run. Instead:

- `/status` in a Tether Claude tab shows `Command line arguments` under
  Setting sources, which means the hooks file loaded.
- Send any prompt: the sidebar shows sparkles, then a green check. Only
  Tether's hooks can produce that.

Each handler sends two headers, interpolated from env vars Tether puts in every
pty:

| Header | Env var | Purpose |
| --- | --- | --- |
| `X-Tether-Pane` | `TETHER_PANE_ID` | Which tab the session lives in |
| `X-Tether-Token` | `TETHER_TOKEN` | Per-launch secret; anything else gets an empty 200 |

## Events

| Event | Path | Timeout | Notes |
| --- | --- | --- | --- |
| UserPromptSubmit, Stop, StopFailure, Notification, SessionEnd, PostToolUse | `/tether/hook` | 10 s | Answered immediately with an empty 200 |
| SessionStart | `/tether/hook` via `curl` | 5 s | **Command hook**, not http: Claude Code runs only command and MCP tool hooks on SessionStart and silently skips an http one. The command posts stdin with the same two headers, prints nothing (SessionStart stdout becomes Claude's context) and always exits 0. |
| PermissionRequest | `/tether/permission` | 600 s | Held open until answered |

HTTP hooks cannot be `async` (that flag is command-hook only), so the server
must answer state hooks fast. It does no I/O before responding.

## Permission mode

Most hook payloads carry `permission_mode`. `SessionRegistry` keeps the last
value it saw, so a Shift+Tab change shows up at the next hook, not instantly:
no hook fires on a mode change alone. Changing a running tab's mode from the
phone is deferred (issue #3).

## State machine

`SessionRegistry.nextState`. Keep this table and the code in sync.

| Hook | Resulting state |
| --- | --- |
| SessionStart | idle |
| UserPromptSubmit | working |
| PermissionRequest | needsInput |
| Notification `permission_prompt`, `agent_needs_input`, `elicitation_dialog`, `elicitation_url_dialog` | needsInput |
| Transcript gets a `[Request interrupted by user…]` user record while working | idle (no hook fires on Esc) |
| Notification `idle_prompt` while working | idle (backup for the above) |
| PostToolUse | working (a tool ran, so any prompt was answered) |
| Stop, last message ends in `?` | needsInput (heuristic: Claude asked a question) |
| Stop, otherwise | done |
| StopFailure | error |
| SessionEnd, pty exit | detached |
| Tab focused while done | idle |
| Permission answered in Tether (allow or deny) | working |

`Session.attention` records *why* a session is `needsInput`: `permission`
(PermissionRequest, or `permission_prompt`), `question` (a Stop ending in `?`, or
`agent_needs_input`), or `dialog` (`elicitation_*`). It is nil in every other
state. A question is answered by typing; the other two must be answered in place,
so Tether will not type queued messages into them (see CHANGES.md).

The sidebar shows the most urgent state across a project's tabs:
needsInput > error > working > done > idle.

Esc detection is the one transition that is not a hook. While a session is
working, Tether reads lines appended to its `transcript_path` once a second
(`TranscriptTail`, `TranscriptSignals.isUserInterrupt`). Only `user` records
count, so Claude quoting the marker does not trigger it. Confirmed on the Mac
mini that `idle_prompt` alone does not clear the badge after Esc.

Tether does not wait for a hook to learn a tab's session. It launches new
Claude tabs with `--session-id <uuid>` and resumed ones with `--resume <id>`,
so the chat mirror can find the transcript by id immediately. On Claude Code
2.1.308 the mirror stayed empty for resumed tabs until the first prompt, which
showed the session was not being reported at startup. The chosen id is only
saved for `--resume` once a hook confirms the session, because resuming an id
that never wrote a transcript fails.

When a pane gets a new session id (`/clear`, resume), the old session is
dropped and the new id is saved so the next launch resumes it.

## Permission prompts

While Tether is running, its prompt replaces Claude Code's terminal prompt:
the hook holds the request until Tether answers. Responses:

| Choice | Hook output |
| --- | --- |
| Allow | `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` |
| Always Allow | Same, plus `updatedPermissions` set to Claude Code's own `permission_suggestions` |
| Deny | `decision: {"behavior":"deny","message":"Denied from Tether."}` |
| Ask in Terminal | Empty 200: no decision, so the normal terminal prompt appears |

Deny and ask rules in your settings still win over an Allow from Tether.

Fallbacks, all of which end at the normal terminal prompt:

- No answer within 585 s: the broker returns Ask in Terminal.
- Tab closed or process exited: pending requests for that pane are released.
- Tether quits or crashes: the connection drops, Claude Code treats it as a
  non-blocking hook error and prompts in the terminal.

## Sample payloads

From the Claude Code hooks reference. Unknown fields are ignored.

```json
{"session_id":"abc123","transcript_path":"/Users/.../00893aaf.jsonl","cwd":"/Users/...",
 "permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash",
 "tool_input":{"command":"rm -rf node_modules","description":"Remove node_modules directory"},
 "permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],
   "behavior":"allow","destination":"localSettings"}]}
```

```json
{"session_id":"abc123","cwd":"/Users/...","hook_event_name":"Notification",
 "message":"Claude needs your permission","title":"Permission needed","notification_type":"permission_prompt"}
```

```json
{"session_id":"abc123","cwd":"/Users/...","hook_event_name":"Stop","stop_hook_active":false,
 "last_assistant_message":"I've completed the refactoring. Here's a summary..."}
```

## Debugging

```bash
cat ~/Library/Application\ Support/Tether/hooks.json
```

```bash
curl -s -X POST "http://127.0.0.1:<port>/tether/hook" \
  -H "X-Tether-Token: wrong" -d '{}' -i
```

The second should return `200` with an empty body: a wrong token is ignored,
never an error that could disrupt a session.
