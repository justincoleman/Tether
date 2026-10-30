import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

@Suite struct CodexHooksTests {
    let project = Project(name: "p", path: "/tmp/p")

    @Test func argumentsAreTheSameOnEveryLaunch() {
        // Codex remembers trusted hooks by hash: nothing per-launch may appear.
        let args = CodexHooks.configArguments()
        #expect(args == CodexHooks.configArguments())
        #expect(args.count == 2 * (CodexHooks.observedEvents.count + 1))
        for (i, arg) in args.enumerated() where i % 2 == 1 {
            #expect(arg.hasPrefix("hooks."))
            #expect(arg.contains("$TETHER_HOOK_PORT"))
            #expect(arg.contains("$TETHER_PANE_ID") && arg.contains("$TETHER_TOKEN"))
        }
        #expect(args.filter { $0 == "-c" }.count == args.count / 2)
    }

    @Test func overrideMatchesTheCapturedShape() {
        let arg = CodexHooks.override(event: "Stop", command: "cat > \"/tmp/x\"", timeout: 10)
        #expect(arg == #"hooks.Stop=[{hooks=[{type="command",command="cat > \"/tmp/x\"",timeout=10}]}]"#)
    }

    @Test func permissionHookPrintsTheAnswerAndObservedHooksDoNot() {
        let permission = CodexHooks.permissionCommand()
        #expect(permission.contains(HookSettings.permissionPath))
        // Only stderr is dropped: stdout carries the decision back to Codex.
        #expect(!permission.contains(" >/dev/null"))
        #expect(permission.hasSuffix(" 2>/dev/null || true"))
        #expect(permission.hasSuffix("|| true"))
        let observe = CodexHooks.observeCommand()
        #expect(observe.contains(HookSettings.hookPath))
        #expect(observe.hasSuffix(">/dev/null 2>&1 || true"))
    }

    @Test func sessionEndStaysWithinCodexsClamp() {
        let args = CodexHooks.configArguments()
        let end = args.first { $0.hasPrefix("hooks.SessionEnd=") }
        #expect(end?.hasSuffix("timeout=3}]}]") == true)
        let permission = args.first { $0.hasPrefix("hooks.PermissionRequest=") }
        #expect(permission?.hasSuffix("timeout=\(HookSettings.permissionTimeoutSeconds)}]}]") == true)
    }

    @Test func tomlStringEscapes() {
        #expect(CodexHooks.tomlString(#"a "b" \c"#) == #""a \"b\" \\c""#)
        #expect(CodexHooks.tomlString("x\ny") == #""x\ny""#)
    }

    @Test func codexLaunchPassesHooksAndPort() {
        let wt = Worktree(projectId: project.id, path: "/tmp/p", branch: "main", isPrimary: true)
        let pane = PaneDescriptor(projectId: project.id, kind: .codex(worktreeId: wt.id, resumeSessionId: nil),
                                  title: "Codex")
        let launch = TerminalLaunch.make(pane: pane, worktree: wt, remoteHost: nil, token: "tok",
                                         hookSettingsPath: "/tmp/hooks.json", newSessionId: "ignored",
                                         hookPort: 4242, shell: "/bin/zsh")
        #expect(launch.workingDirectory == "/tmp/p")
        #expect(launch.environment[CodexHooks.portEnvKey] == "4242")
        #expect(launch.environment[TerminalLaunch.tokenEnvKey] == "tok")
        let command = launch.command ?? ""
        #expect(command.hasPrefix("/bin/zsh -l -c 'codex -c "))
        #expect(!command.contains("--settings") && !command.contains("--session-id"))
        #expect(!command.contains("4242"))
    }

    @Test func codexLaunchWithoutHooksIsBare() {
        let wt = Worktree(projectId: project.id, path: "/tmp/p", branch: "main", isPrimary: true)
        let pane = PaneDescriptor(projectId: project.id, kind: .codex(worktreeId: wt.id, resumeSessionId: nil),
                                  title: "Codex")
        let launch = TerminalLaunch.make(pane: pane, worktree: wt, remoteHost: nil, token: "t", shell: "/bin/zsh")
        #expect(launch.command == "/bin/zsh -l -c codex")
        #expect(launch.environment[CodexHooks.portEnvKey] == nil)
    }

    @Test func codexResumesAndStartsOnPrompts() {
        let wt = Worktree(projectId: project.id, path: "/tmp/p", branch: "main", isPrimary: true)
        let resumed = PaneDescriptor(projectId: project.id, kind: .codex(worktreeId: wt.id, resumeSessionId: "T1"),
                                     title: "Codex")
        let r = TerminalLaunch.make(pane: resumed, worktree: wt, remoteHost: nil, token: "t",
                                    initialPrompt: "ignored", shell: "/bin/zsh")
        #expect(r.command == "/bin/zsh -l -c 'codex resume T1'")
        let fresh = PaneDescriptor(projectId: project.id, kind: .codex(worktreeId: wt.id, resumeSessionId: nil),
                                   title: "Codex")
        let f = TerminalLaunch.make(pane: fresh, worktree: wt, remoteHost: nil, token: "t",
                                    initialPrompt: "fix it\n", shell: "/bin/zsh")
        #expect(f.command == "/bin/zsh -l -c 'codex '\\''fix it'\\'''")
    }

    @Test func paneKindHelpers() {
        let wt = UUID()
        #expect(PaneKind.codex(worktreeId: wt, resumeSessionId: nil).agent == .codex)
        #expect(PaneKind.claude(worktreeId: wt, resumeSessionId: nil).agent == .claude)
        #expect(PaneKind.shell(cwd: "/").agent == nil)
        #expect(PaneKind.codex(worktreeId: wt, resumeSessionId: nil).worktreeId == wt)
        #expect(PaneKind.codex(worktreeId: wt, resumeSessionId: nil).resuming("T")
                == .codex(worktreeId: wt, resumeSessionId: "T"))
        #expect(PaneKind.shell(cwd: "/").resuming("T") == .shell(cwd: "/"))
    }

    @Test func oldLayoutsStillDecode() throws {
        let wt = UUID()
        let old = try JSONEncoder().encode(PaneKind.claude(worktreeId: wt, resumeSessionId: "S"))
        #expect(try JSONDecoder().decode(PaneKind.self, from: old) == .claude(worktreeId: wt, resumeSessionId: "S"))
        let codex = try JSONEncoder().encode(PaneKind.codex(worktreeId: wt, resumeSessionId: nil))
        #expect(try JSONDecoder().decode(PaneKind.self, from: codex) == .codex(worktreeId: wt, resumeSessionId: nil))
    }
}

/// Hook bodies captured from Codex 0.164 on 2026-10-30 (`codex exec` with
/// `-c` hooks), with the paths shortened. docs/HOOKS.md, "Codex".
@Suite struct CodexHookPayloadTests {
    static let base = #""session_id":"01a18a4e-3d53-7962-bd71-f2fa8f85723b","transcript_path":"/Users/u/.codex/sessions/2026/10/29/rollout-2026-10-29T20-55-45-01a18a4e-3d53-7962-bd71-f2fa8f85723b.jsonl","cwd":"/tmp/proj""#
    static let sessionStart = #"{"# + base + #","hook_event_name":"SessionStart","model":"gpt-6.1-sol","permission_mode":"bypassPermissions","source":"startup"}"#
    static let prompt = #"{"# + base + #","turn_id":"t1","hook_event_name":"UserPromptSubmit","model":"gpt-6.1-sol","permission_mode":"bypassPermissions","prompt":"Run the shell command `ls`"}"#
    static let postTool = #"{"# + base + #","turn_id":"t1","hook_event_name":"PostToolUse","model":"gpt-6.1-sol","permission_mode":"bypassPermissions","tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":"README.md\n","tool_use_id":"exec-1"}"#
    static let stop = #"{"# + base + #","turn_id":"t1","hook_event_name":"Stop","model":"gpt-6.1-sol","permission_mode":"bypassPermissions","stop_hook_active":false,"last_assistant_message":"done"}"#
    static let sessionEnd = #"{"# + base + #","hook_event_name":"SessionEnd","reason":"other"}"#
    /// Not captured: Interrupt's documented common fields.
    static let interrupt = #"{"# + base + #","turn_id":"t2","hook_event_name":"Interrupt","model":"gpt-6.1-sol","permission_mode":"default"}"#

    func decode(_ json: String) throws -> HookPayload {
        try JSONDecoder().decode(HookPayload.self, from: Data(json.utf8))
    }

    @Test func capturedBodiesDecode() throws {
        let start = try decode(Self.sessionStart)
        #expect(start.hookEventName == .sessionStart)
        #expect(start.sessionId == "01a18a4e-3d53-7962-bd71-f2fa8f85723b")
        #expect(start.transcriptPath?.hasSuffix("01a18a4e-3d53-7962-bd71-f2fa8f85723b.jsonl") == true)
        #expect(start.permissionMode == "bypassPermissions")
        #expect(try decode(Self.postTool).toolName == "Bash")
        #expect(try decode(Self.stop).lastAssistantMessage == "done")
        #expect(try decode(Self.sessionEnd).hookEventName == .sessionEnd)
        #expect(try decode(Self.interrupt).hookEventName == .interrupt)
    }

    @Test func aCodexTurnDrivesTheSidebar() async throws {
        let r = SessionRegistry()
        let pane = PaneID()
        let start = try decode(Self.sessionStart), prompt = try decode(Self.prompt)
        let tool = try decode(Self.postTool), stop = try decode(Self.stop)
        let interrupt = try decode(Self.interrupt), end = try decode(Self.sessionEnd)
        #expect(await r.apply(start, paneId: pane).state == .idle)
        #expect(await r.apply(prompt, paneId: pane).state == .working)
        #expect(await r.apply(tool, paneId: pane).state == .working)
        #expect(await r.apply(stop, paneId: pane).state == .done)
        #expect(await r.apply(prompt, paneId: pane).state == .working)
        #expect(await r.apply(interrupt, paneId: pane).state == .idle)
        #expect(await r.apply(end, paneId: pane).state == .detached)
        #expect(await r.apply(interrupt, paneId: pane).state == .detached)
    }
}
