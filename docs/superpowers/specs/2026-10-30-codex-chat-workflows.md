# Codex conversations and cross-agent workflows

Scope approved in chat: include a working app-server transport in this release,
alongside the rollout-file chat mirror, health reporting, folder collision
warnings, cross-agent review, and handoff. Bump the version and release notes.

## Conversation sources

Existing Codex terminal tabs retain terminal ownership. Their session hooks
identify the thread and rollout path. A dedicated Codex parser emits the same
public MirrorEvents used by Claude, so the Mac, paired Macs, and phone render
one conversation model. Discover only the specific tracked session; do not
import unrelated conversations or write any Codex/Claude global configuration.
Ignore system/developer messages, reasoning, internal agent messages, and
duplicate event-level copies. Bound initial reads and run discovery off main.

New Codex Chat tabs use a separate stdio app-server process per pane. Persist
the transport choice on the pane descriptor; old descriptors default to the
terminal. Never resume a terminal-owned thread through app-server while that
terminal is running. Start/resume, send, stop, tool approvals, and user-input
requests travel over JSON-RPC. Native chat owns its process and uses structured
events/history; it never mounts a second terminal process. EOF/timeouts drain
requests, show errors, and retain recoverable user input. Unsupported server
requests fail explicitly without granting permission. No dependencies or API
keys are introduced; the installed Codex CLI uses its existing sign-in.

## Visibility and reliability

A live terminal Codex pane with no report after a startup grace period shows
"Codex isn't reporting", with hook/trust guidance and a terminal action. A
previously reported idle pane is not diagnosed as broken from silence. Native
chat shows actual connection/startup/error status. Expose relevant status to the
phone. Push alerts name the actual agent; Live Activity copy is agent-neutral.

Show a warning when live Claude and Codex panes resolve to the same exact
folder, including symlink aliases. Separate worktrees do not collide. The
warning explains that edits affect both tabs; it does not silently move files.

## Review and handoff

An explicit action on an agent tab offers Review with the other agent and
Hand off to the other agent. Show an editable preview naming the source,
destination, exact worktree, base branch, changed files, and bounded public
conversation context. Review is inspection only: launch Claude in plan mode or
native Codex with a read-only sandbox. Handoff starts a fresh destination
conversation in the same worktree after the source is ready; preserve the source
history and uncommitted files. Never inject into an unrelated existing tab.
Send through the existing safe prompt/queue gate. Use app-server review/start
for native Codex review, with the preview instructions as a custom target.

## Validation

Regression tests cover sanitized rollout records, duplicate/private suppression,
discovery isolation, report grace, exact-folder collisions, push agent names,
cross-agent context bounds, RPC framing/results/errors/shutdown, and native turn
event/approval handling. A no-inference smoke test initializes the installed
app-server. Build both apps and inspect the native UI and final bundle version.
Update TRANSCRIPT, HOOKS, PROTOCOL, and CHANGES for affected contracts.
