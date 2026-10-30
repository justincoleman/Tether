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
| (status line, not a hook) | `/tether/status` | 1 s | See Status line below |

HTTP hooks cannot be `async` (that flag is command-hook only), so the server
must answer state hooks fast. It does no I/O before responding.

## Status line

The hooks file also sets `statusLine`, the only place Claude Code reports the
model, the session cost and plan limits. The command (`HookSettings.statusLine`)
reads stdin once, posts it to `/tether/status` with the same two headers
(`curl --max-time 1`, output discarded), then pipes the same JSON into the
user's own status line command, so the terminal looks as it did:

```
input=$(cat); printf '%s' "$input" | curl … /tether/status >/dev/null 2>&1; printf '%s' "$input" | {
<user's command>
}
```

`statusLine` is not a list key, so the `--settings` one replaces the user's.
Tether reads `statusLine` from `~/.claude/settings.json` at launch (only
`type: command`) and copies its other keys (e.g. `padding`). A change to it takes
effect when Tether restarts. A `statusLine` set in a project's own
`.claude/settings*.json` is not chained. With no user status line the relay
prints nothing.

`StatusLineReport` reads these fields; everything else is ignored:

| Field | Becomes |
| --- | --- |
| `session_id` | required, else ignored |
| `model.id`, `model.display_name` | `SessionStatus.modelId`, `modelName` |
| `cost.total_cost_usd` | `SessionStatus.costUSD` |
| `context_window.context_window_size`, else 1M when `model.id` ends in `[1m]` | `SessionStatus.contextWindow`, which overrides the transcript's guessed window in both context meters |
| `rate_limits.five_hour` / `seven_day` `.used_percentage`, `.resets_at` (epoch seconds; ISO 8601 also accepted) | `UsageLimits` (absent for API-key sessions, and until a session's first reply) |

The router emits `.status(paneId:)` without touching `SessionRegistry`: the
status line never changes session state. `AppModel` keeps the status per tab
and the latest limits, and sends them to phones in the snapshot. Because a
relaunched tab reports no `rate_limits` until its first reply, the latest limits
are saved in UserDefaults (`SavedLimits`) and restored at launch; a window whose
`resets_at` has passed is dropped, both on restore and when building a snapshot.
The fixture in `StatusLineTests` matches the shape of a payload captured from
Claude Code 2.1.308 (all four `rate_limits` values are JSON numbers).

## Switching the model

The phone's `setModel` makes the Mac type `/model <name>` through
`AppModel.sendOrQueue`, so it waits for the turn to end like any message.
`ModelCommand` allows only alias and model-id characters. `PromptQueue.drain`
sends a slash command on its own, never joined to other queued text (which would
become its arguments). A slash command fires no hook, so after typing one the
Mac retries the queue a second later.

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
| Interrupt (Codex only: the user pressed Esc) | idle, unless detached |
| SessionEnd, pty exit | detached |
| SessionEnd for a session the pane already replaced (/clear, a forking resume) | ignored: the pane keeps its current session |
| Status line report while detached and the pty is alive | idle (Claude only draws its status line while running) |
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

## Questions (AskUserQuestion)

PermissionRequest fires for Claude's `AskUserQuestion` tool with
`tool_input.questions = [{header, question, multiSelect, options: [{label, description}]}]`
(captured from Claude Code 2026-10-29). When there is exactly one question and it is not
`multiSelect`, `AskUserQuestion.prompt` turns it into a card on the Mac (chat and terminal view),
the phone and paired Macs. Picking an option, or typing an answer, replies with
`decision: {behavior: "allow", updatedInput: {...tool_input, answers: {<question>: <answer>}}}`
(`PermissionDecision.allowWithInput`). That `answers` shape is the one Claude's SDK `canUseTool` uses;
if a Claude Code update ignores it the tool would run with no answer, so "Ask in Terminal" stays on the
card. Several questions, or multi-select, keep the plain permission card. Bare Return never answers one.

## Folder trust

Claude Code asks "Do you trust the files in this folder?" before it starts in a folder it
hasn't opened, and no hook fires until that is answered. `AppModel.scheduleTrustCheck` looks at
a new Claude tab 3 s and 7 s after launch: if no hook has reported a session, no status line has
arrived, and `FolderTrust.isTrusted` (reads `~/.claude.json`, `projects[path].hasTrustDialogAccepted`,
the folder or any parent) says the folder is unknown, it adds a `PendingPermission` with tool name
`TrustFolder`. The Mac card, the phone and paired Macs show it like a permission. The phone push
goes out only at the 7 s check, so a slow start doesn't buzz the phone.

- Trust sends Down then Return to the tab, Don't Trust sends Esc, Ask in Terminal dismisses the card.
  The dialog (captured 2026-10-29) lists "No, exit" first and highlighted, then "Yes, I trust this
  folder", with no numbers: a bare Return quits Claude. If a Claude Code update reorders it, this
  is the line to change.
  Tether never writes the config or trusts a folder itself.
- The first hook or status line report for the tab removes the card (Claude only runs either once
  it is past the question, so it was answered in the terminal).
- Until a hook or status line arrives, chat view shows "Starting Claude", then after 5 s a
  "Show Terminal" button (Claude may be asking something chat can't show), and the Mode and Model
  menus stay disabled: their Shift-Tab or `/model` would land in the terminal question.
  Messages sent meanwhile queue (`canSendNow` needs a state).
- An unreadable or missing `~/.claude.json` counts as trusted: no card is better than a wrong one.
- Return and Esc in an empty chat box answer ordinary permissions but never this one.

## Codex

Codex tabs (`PaneKind.codex`) report to the same hook server and state machine
as Claude tabs. Codex 0.164 (captured 2026-10-30 on the Mac mini) sends hook
bodies with Claude's field names: `session_id` (the thread id, also the uuid in
the rollout file name), `transcript_path` (the rollout under
`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`), `cwd`, `hook_event_name`,
`model`, `permission_mode` (Claude's mode names: `bypassPermissions` when
approvals are off), `tool_name` (`Bash` for shell commands), `tool_input`,
`last_assistant_message` on Stop. Captured bodies are fixtures in
`CodexHooksTests`.

Wiring (`CodexHooks`, `TerminalLaunch`):

- Codex runs only `command` hooks, so each hook is a `curl` that posts stdin to
  `/tether/hook` (observed events, prints nothing) or `/tether/permission`
  (prints Tether's answer, same `hookSpecificOutput.decision` shape as Claude).
  Every command ends in `|| true`: a missing Tether never blocks Codex.
- They are passed per launch as `-c hooks.<Event>=[{hooks=[{type="command",command="…",timeout=N}]}]`.
  Tether never writes `~/.codex/config.toml` or a project's `.codex/`.
- Events: SessionStart, UserPromptSubmit, PostToolUse, Stop, Interrupt,
  SessionEnd (timeout 3s: Codex clamps SessionEnd to that), PermissionRequest
  (600s, like Claude).
- Codex asks the user to review new or changed hooks once ("Hooks need
  review", then Trust all) and remembers them by hash across launches and
  upgrades. So the arguments never change between launches: the port comes
  from `TETHER_HOOK_PORT`, pane and token from `TETHER_PANE_ID` and
  `TETHER_TOKEN`, all in the pty's environment. Without that review the hooks
  are skipped silently. Tether does not pass `--dangerously-bypass-hook-trust`,
  which would also skip review of every other hook on the run.
- Codex has no `--session-id`, so a new Codex tab learns its thread id from
  SessionStart. A recorded id is resumed with `codex resume <id>`.
- `Interrupt` replaces Claude's transcript-polling Esc detection.

Not yet wired: the chat mirror (the rollout is a different format), the model
menu (Codex's `/model` differs), folder trust cards (Codex's prompt lists
"Trust and continue" first, so a bare Return trusts), questions
(`request_user_input`), and "Always allow" (Codex sends no
`permission_suggestions`, so it allows once). Codex's "Approaching rate
limits, switch model?" popup takes the next Return, so a queued message sent
while it shows picks "Switch". Not verified: whether SessionStart fires when
the TUI starts or only with the first prompt, and the PermissionRequest
answer shape on a real approval.
