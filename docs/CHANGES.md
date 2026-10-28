# Changes panel, diffs, and review comments

How Tether shows what a branch changed, and how selected lines become a message
to Claude. Code: `Sources/TetherCore/Git*.swift`, `UnifiedDiff.swift`,
`ReviewMessage.swift`, `PromptQueue.swift`; app side in `Apps/Tether/Changes/`.

## What the panel compares

Files are compared against the **merge base** of HEAD and the base branch, not
the tip of the base. Commits that landed on the base after this branch started
therefore never show up as reversed changes. Being behind is shown as `↓N`.

The base is the first of these that shares history with HEAD:

1. `origin/<project base branch>` (default `main`)
2. the branch `origin/HEAD` points at
3. the local base branch, when you are on a different branch

If none exists (a repository with no remote), the panel shows **uncommitted
changes against HEAD** and says so. With no commits at all it lists the files
git reports, without line counts. A folder that is not a repository shows
"Not a git repository".

The file list is `git diff --name-status -z -M` plus `--numstat -z -M` against
the merge base (committed and uncommitted tracked changes together), then
untracked files from `git status`, which diff does not cover. A dot marks files
with uncommitted changes. Caps: 1000 files, 200 untracked files line-counted,
5000 lines per diff, files over 1 MB are not previewed.

Per-file diffs are loaded when you open a file, not with the list.

## Git, shelled out

All reads go through `GitRunner` (`/usr/bin/env git`). Every call sets
`GIT_OPTIONAL_LOCKS=0`, so reading status never rewrites the index (which the
file watcher would see, forever), and `GIT_TERMINAL_PROMPT=0`. Calls time out
after 30 s. Output formats and their traps are covered by tests built from real
git 2.43 output (`GitParsingTests`):

- `status --porcelain=v2 -z`: paths may contain spaces, so fields are split with
  a limit, and a rename's original path is the *next* NUL record.
- `numstat -z`: a rename is `adds\tdels\t` with an empty path, then old, then
  new path as separate records. Binary files report `-`.
- Diff bodies are parsed using the hunk header's line counts, so a deleted line
  whose text is `--- x` is not mistaken for a file header. The counting logic was
  fuzzed against `git diff --numstat` on random repositories (449 files, 0
  mismatches).

## Staying fresh

`ChangesStore` follows every project's folder:

- **File events** (FSEvents), filtered by `GitEventFilter`: build output
  (`build`, `.build`, `node_modules`, `DerivedData`, …) and git internals such as
  `.git/objects` and `*.lock` are ignored; `.git/HEAD`, `index` and `refs`
  count. Events are debounced 300 ms, and a refresh is never starved for more
  than 2 s. A repository that *tracks* one of the ignored directory names will
  not update live for it. Opening the panel or ending a Claude turn refreshes
  anyway.
- **After each Claude turn** the panel refreshes, and the base branch is fetched
  (rate-limited to once per 20 s per folder).
- **Fetch timer**: the focused folder every 2 minutes, others every 10. Fetch
  runs `git fetch origin <base>` with `BatchMode=yes` for ssh, a 45 s timeout,
  and no credential prompts, so a missing key fails fast. The panel footer shows
  "Fetched 3m ago" or "Fetch failed" (hover for the reason).
- Linked git worktrees keep their git directory elsewhere, so `HEAD`/`index`
  moves there are not watched yet. Revisit with phase 6 worktrees.

The sidebar shows each project's current branch from the same snapshots.

## Diff viewer and review comments

Opening a file covers the terminal area (the tab strip stays; picking a tab
closes the diff). Esc clears the selection, then closes.

Rows are a fixed 18 pt with no wrapping and a horizontal scroll, so a pointer
position maps to a row by division. Click or drag to select lines, Shift-click
to extend; hunk headers are never selected.

With lines selected, type what Claude should do, then:

- **Add Comment** keeps it and lets you keep reviewing, or
- **Send to Claude** (⌘↩) adds the current comment and sends everything.

One comment becomes:

````
In `path/to/file.swift`, lines 28–33:

```swift
<selected lines>
```

<your instruction>
````

Several become "Please address these review comments on the current changes:"
and a numbered list. Selections are described by their line numbers in the
*current* file. Only removed lines: "removed lines 10–12 (previous version)".
Both: shown as a `diff` block with `+`/`-` markers. The code fence grows when
the code contains backticks.

After sending, Tether returns to the Claude tab. Pending comments stay while
you move between files, and are dropped when sent.

## Sending while Claude is busy

`PromptGate` decides when typing is safe:

| State | Send now? |
| --- | --- |
| idle, done, error | yes |
| needsInput because Claude asked a question | yes |
| needsInput because of a permission prompt or dialog | no: typing would answer it |
| working | no: typing would interrupt the turn |
| detached (Claude exited) | no |

Otherwise the message waits in `PromptQueue` and goes out as soon as a hook
event says Claude is ready. Several queued messages are sent together as one
message. The chat view shows "N messages queued". The queue lives in memory
only and is lost if Tether quits.

`Session.attention` (permission, question, dialog) carries the reason a session
is waiting; protocol version 3.
