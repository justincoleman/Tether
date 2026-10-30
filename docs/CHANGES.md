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

## Staging

The panel is read-only apart from the index. A file with uncommitted changes
shows a circle (unstaged), a half circle (partly staged) or a check (staged)
from `git status` (`StatusEntry.staging`). Clicking it, the row's context menu,
or Stage All / Unstage All in the header run:

- stage: `git --literal-pathspecs add -A -- <paths>`, which picks up deletions
  and new files. A rename passes both paths.
- unstage: `git --literal-pathspecs restore --staged -- <paths>`, or
  `git rm --cached -r -q` before the first commit, when there is no HEAD.

Paths are literal, so `app/[id]/page.tsx` is a file name and not a glob.
Conflicts have no toggle, because they're resolved rather than staged. The
phone doesn't see staging: it only gets the snapshot. A failure shows "Staging
failed" in the footer (hover for git's message). Tested in
`GitRepositoryTests.stagingFollowsTheIndex`.

## Pull requests and checks

`PullRequestStore` asks the GitHub CLI about every worktree whose branch isn't
its project's base: `gh pr view <branch> --json
number,title,url,state,isDraft,statusCheckRollup`, run in the worktree with
`GH_PROMPT_DISABLED=1`. `gh` is optional. It is found at `/opt/homebrew/bin`,
`/usr/local/bin` or `/usr/bin`, because apps opened from the Dock don't get the
login shell's PATH. Without it, or with any error (signed out, offline, not a
GitHub remote), no badge is shown. "no pull requests found" is the normal
answer for a branch with no PR.

- **Parsing** (`PullRequestParser`, tested in `PullRequestTests`): a `CheckRun`
  passes on SUCCESS, NEUTRAL or SKIPPED, is pending until COMPLETED, and fails
  on anything else. A `StatusContext` passes on SUCCESS, is pending on PENDING
  or EXPECTED, and fails otherwise. Any failure makes the whole PR failing, then
  anything pending makes it pending. The fixture follows gh 2.x's documented
  shape. Replace it with captured output the first time gh changes it.
- **Timing** (`PullRequestPolicy`): 20 s while checks run, 90 s otherwise, and
  10 minutes once merged or closed. At least 5 minutes while Tether is in the
  background, and 3× slower in Low Power Mode. The end of a Claude turn asks
  again on the next 10 s pass, since that turn may have pushed or opened the PR.
- The badge (`#12` with a check, cross or clock) sits next to the branch in the
  sidebar and in the Overview, and clicking it opens the PR. A merged PR marks
  its worktree as merged even when git can't tell (squash merges).

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

After sending, Tether returns to the Claude tab. Pending comments belong to the
project and worktree where they were written. They stay while you move between
files in that worktree, and are dropped only when sent or queued successfully.
Reviews go only to a running Claude tab in that same worktree, preferring the
selected tab when it matches. Tabs in another worktree never receive the review.
If no matching live tab exists (including an exited or detached tab), the diff
stays open with its draft and pending comments intact, and asks you to open a
Claude tab in that worktree.

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
message. The chat view shows each queued message as a bubble with Edit,
Remove and Send Now. Edits and removals name the message's index and text, so
nothing changes if the queue moved under the user. Send Now (or Control-Return
in the message box, `AppModel.sendNow`) moves the message to the front marked
solo: it drains by itself, like a slash command, and the rest stay queued. If
Claude is working, Tether presses Esc; the interrupt record sets the pane idle
and the queue flushes. A pane waiting on a permission prompt is not
interrupted; the message goes once the user answers. The queue lives in memory
only and is lost if Tether quits.

`Session.attention` (permission, question, dialog) carries the reason a session
is waiting; protocol version 3.

A failed terminal write schedules at most five delayed retries, with one task
per pane. Repeated scheduling joins that task instead of resetting its budget.
Closing the pane cancels its task. Exhaustion leaves the message queued; a later
ready hook or send can attempt delivery again. Slash commands remain separate
from following messages during retries.


## Cross-agent review and handoff (0.30.16)

The tab toolbar offers Review with the other agent and Hand off. Each opens an
editable preview naming the exact source folder, comparison base, changed file
names and bounded public conversation context. Tool output and private reasoning
are excluded. The source must be idle, done, or waiting on a normal question;
working turns and approval/dialog waits must be finished or stopped first.

Confirmation rechecks the source pane, worktree, current branch and commit, then
opens a fresh target tab on the same WorktreeID. It never injects into an unrelated
agent tab or switches to the project's primary checkout. Codex reviews use native
`review/start` with a custom target and read-only sandbox. Claude reviews use plan
mode, including after restart. Handoff preserves source history and working files.

PR actions use GitHub CLI with structured argv and fresh branch/head validation.
Create requires a published branch and explicit title/body; Tether never pushes it
implicitly. Merge uses squash with `--match-head-commit`; reruns select failed
Actions runs for the reviewed commit. The phone and paired Mac use the same host
implementation. Action errors remain visible and ambiguous receipts are not retried.
