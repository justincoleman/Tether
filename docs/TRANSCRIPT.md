# Claude Code transcripts in Tether

The chat mirror reads each session's transcript,
`~/.claude/projects/<encoded cwd>/<session id>.jsonl`. Tether knows the session
id from launch (see HOOKS.md) and finds the file with `TranscriptLocator`,
which matches `<session id>.jsonl` in any project directory instead of
reproducing Claude Code's directory-name encoding. A hook's `transcript_path`
takes over once one arrives. The format is
not a public contract. This file records what Tether relies on, as observed in
Claude Code 2.1.308. Code: `Sources/TetherCore/TranscriptParser.swift`,
`Sources/TetherProtocol/TranscriptModel.swift`.

## Records Tether reads

One JSON object per line. Only `type` `user` and `assistant` are read; every
other type is skipped (`attachment`, `system`, `mode`, `last-prompt`,
`queue-operation`, `cost-state`, `tools-used`, `custom-title`, `agent-name`,
`atis-latch`, and anything new).

Skipped regardless of type:
- `isSidechain: true`: subagent turns.
- `isMeta: true`: context Claude Code injected, such as image paths and
  reminders, not text anyone typed.
- Records without a `uuid`.

### assistant

Claude Code writes **one record per content block**, all sharing
`message.id`. Each record also carries `message.usage`.

Records with `message.model == "<synthetic>"` are placeholders Claude Code
writes itself (e.g. "No response requested." after an interrupt). They never
appear in the terminal and are skipped. A text block that is exactly
"No response requested." is skipped too, in case the marker changes.

| Block | Becomes |
| --- | --- |
| `text` | assistant message |
| `tool_use` (`id`, `name`, `input`) | tool step, summarised like the permission prompt |
| `thinking`, anything else | skipped |

Context used = `input_tokens + cache_creation_input_tokens +
cache_read_input_tokens` from the latest record. The window size is not in the
transcript: `message.model` is the API id (`claude-opus-5-5`) with no `[1m]`
marker. `TranscriptFeed` reads `model` from `~/.claude/settings.json` (where
`/model` saves the choice) whenever a batch has usage: a value ending in `[1m]`
means 1M. Otherwise Tether assumes 200k, or 1M once usage passes 200k. Project
settings, `--model` and `ANTHROPIC_MODEL` are not consulted. The meters prefer
the status line's `context_window_size` (`SessionStatus.contextWindow`, see
docs/HOOKS.md) over this guess whenever it has reported.

### user

`message.content` is a string or a list of blocks.

| Content | Becomes |
| --- | --- |
| Plain text | your message |
| Text starting `[Request interrupted by user` | "Interrupted" notice |
| `<command-name>/x</command-name>…<command-args>y</command-args>` | your message `/x y` |
| Other text starting with `<` (`<local-command-stdout>`, caveats, reminders) | skipped |
| `image` block | `[image]` appended to your message |
| `tool_result` (`tool_use_id`, `content` string or list, `is_error`) | result on the matching step: the last 6 non-empty lines, 300 chars each (views show the first line for tools other than Bash) |

## Formatting

Assistant text is split into blocks by `MarkdownBlocks` (headings, lists,
tables, fenced code, quotes, rules) in `TetherProtocol`, and rendered by
`Apps/Shared/MarkdownView.swift`, which both apps compile. Inline formatting
inside a block uses Foundation's inline markdown.

## Display grouping

`TranscriptModel` folds events into rows. Consecutive tool calls become one
collapsed "N steps · used X, ran Y" row (ran = `Bash`). Text between tool calls
starts a new group. Applying the same event twice is a no-op, so re-reading a
file is safe.

## Session history

The History popover lists past sessions with `SessionHistory`
(`Sources/TetherCore/SessionHistory.swift`). It looks in
`~/.claude/projects/<encoded folder>/` for the project folder and each
worktree. The encoding replaces every character other than an ASCII letter or
digit with `-`; when that folder doesn't exist (Claude Code shortens long
names) it checks each folder's first transcript for a matching `cwd`.
`agent-*.jsonl` files are subagents and are skipped. Only the first 128 KB
and last 64 KB of each file are read; lines cut at a chunk edge don't parse
and are skipped.

| Record | Used for |
| --- | --- |
| `custom-title` (`customTitle`, from `/rename`) | title, wins over the rest |
| `ai-title` (`aiTitle`, rewritten as the session goes) | title, last one seen |
| `summary` (`summary`, older versions) | title fallback |
| first `user` record that isn't `isMeta` or `isSidechain` | first prompt, same text rules as the mirror (`<command-name>` reads as `/x args`, other `<…>` text and interrupts are not prompts) |
| `user` `cwd` (first) and `gitBranch` (last) | folder to resume in, branch label |

A file with no prompt is left out. Last activity is the file's modification
time. Opening a session runs `claude --resume <id>` in the worktree whose path
equals its `cwd` (the primary worktree otherwise), or selects the tab already
running it.

## When the format changes

Unknown records and blocks are skipped, never fatal. If the mirror goes quiet
after a Claude Code update, compare a fresh transcript against this file:

```bash
F=$(ls -t ~/.claude/projects/*/*.jsonl | head -1)
python3 -c "import json,sys,collections; c=collections.Counter(json.loads(l).get('type') for l in open(sys.argv[1])); print(c)" "$F"
```


## Tool detail and stopped calls

- `tool_use` for `Read`, `Edit`, `MultiEdit`, `Write` and `NotebookEdit` also yields a
  `toolDetail` event (protocol 17): the absolute `file_path`/`notebook_path`, and for
  edits the lines removed and added with the common leading and trailing lines
  trimmed (24 lines max per side, 200 chars each). `Write` and `NotebookEdit` list the
  new content as added lines. The Mac chat opens the file when it is inside the tab's folder.
- A denied or interrupted call arrives as an error `tool_result` whose text starts with
  `[Request interrupted by user`, `The user rejected`, or contains
  `doesn't want to proceed with this tool use`, or is `Permission to use … denied`.
  `ToolStep.isStopped` matches these so the chat says "Stopped", not "Failed". The
  strings are taken from memory of Claude Code output, not a captured fixture: confirm
  against a real denied command and adjust `isStopped` if they differ.
