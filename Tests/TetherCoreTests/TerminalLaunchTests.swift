import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

@Suite struct TerminalLaunchTests {
    let project = Project(name: "p", path: "/tmp/p")

    @Test func claudeLaunchResumesAndTagsPane() {
        let wt = Worktree(projectId: project.id, path: "/tmp/p", branch: "main", isPrimary: true)
        let pane = PaneDescriptor(projectId: project.id, kind: .claude(worktreeId: wt.id, resumeSessionId: "abc"), title: "Claude")
        let launch = TerminalLaunch.make(pane: pane, worktree: wt, remoteHost: nil, token: "tok", shell: "/bin/zsh")
        #expect(launch.workingDirectory == "/tmp/p")
        #expect(launch.command == "/bin/zsh -l -c 'claude --resume abc'")
        #expect(launch.environment[TerminalLaunch.paneEnvKey] == pane.id.uuidString)
        #expect(launch.environment[TerminalLaunch.tokenEnvKey] == "tok")
    }

    @Test func newSessionCanStartOnAPrompt() {
        let wt = Worktree(projectId: project.id, path: "/tmp/p", branch: "main", isPrimary: true)
        let pane = PaneDescriptor(projectId: project.id, kind: .claude(worktreeId: wt.id, resumeSessionId: nil), title: "Claude")
        let launch = TerminalLaunch.make(pane: pane, worktree: wt, remoteHost: nil, token: "t",
                                         newSessionId: "S1", initialPrompt: "Fix the login bug's test\n", shell: "/bin/zsh")
        #expect(launch.command == "/bin/zsh -l -c 'claude --session-id S1 '\\''Fix the login bug'\\''\\'\\'''\\''s test'\\'''")
        // Resuming ignores the prompt: the old conversation continues.
        let resumed = PaneDescriptor(projectId: project.id, kind: .claude(worktreeId: wt.id, resumeSessionId: "abc"), title: "Claude")
        let r = TerminalLaunch.make(pane: resumed, worktree: wt, remoteHost: nil, token: "t",
                                    initialPrompt: "hello", shell: "/bin/zsh")
        #expect(r.command == "/bin/zsh -l -c 'claude --resume abc'")
    }

    @Test func shellLaunchHasNoCommand() {
        let pane = PaneDescriptor(projectId: project.id, kind: .shell(cwd: "/tmp/x"), title: "Shell")
        let launch = TerminalLaunch.make(pane: pane, worktree: nil, remoteHost: nil, token: "t")
        #expect(launch.command == nil)
        #expect(launch.workingDirectory == "/tmp/x")
    }

    @Test func sshLaunchUsesUserAtHost() {
        let host = RemoteHost(name: "mini", host: "mini.tail.net", user: "justin")
        let pane = PaneDescriptor(projectId: project.id, kind: .ssh(hostId: host.id), title: "mini")
        let launch = TerminalLaunch.make(pane: pane, worktree: nil, remoteHost: host, token: "t", shell: "/bin/zsh")
        #expect(launch.command == "/bin/zsh -l -c 'ssh -t justin@mini.tail.net'")
    }

    @Test func quotingEscapesSingleQuotes() {
        #expect(TerminalLaunch.shellQuote("it's") == "'it'\\''s'")
        #expect(TerminalLaunch.shellQuote("plain-1.0") == "plain-1.0")
    }

    @Test func promptTextStripsTrailingNewlines() {
        #expect(TerminalLaunch.promptText("fix it\n\n") == "fix it")
        #expect(TerminalLaunch.promptText("a\nb") == "a\nb")
    }
}

@Suite struct TerminalLaunchSettingsTests {
    @Test func claudeGetsQuotedSettingsPath() {
        let project = Project(name: "p", path: "/tmp/p")
        let wt = Worktree(projectId: project.id, path: "/tmp/p", branch: "main", isPrimary: true)
        let pane = PaneDescriptor(projectId: project.id, kind: .claude(worktreeId: wt.id, resumeSessionId: nil), title: "Claude")
        let launch = TerminalLaunch.make(pane: pane, worktree: wt, remoteHost: nil, token: "t",
                                         hookSettingsPath: "/Users/j/Library/Application Support/Tether/hooks.json",
                                         shell: "/bin/zsh")
        // Inner quotes protect the space; outer quoting escapes them for -c.
        #expect(launch.command == #"/bin/zsh -l -c 'claude --settings '\''/Users/j/Library/Application Support/Tether/hooks.json'\'''"#)
    }
}

@Suite struct TerminalLaunchSessionIdTests {
    let project = Project(name: "p", path: "/tmp/p")

    @Test func newSessionGetsChosenId() {
        let wt = Worktree(projectId: project.id, path: "/tmp/p", branch: "main", isPrimary: true)
        let pane = PaneDescriptor(projectId: project.id, kind: .claude(worktreeId: wt.id, resumeSessionId: nil), title: "Claude")
        let launch = TerminalLaunch.make(pane: pane, worktree: wt, remoteHost: nil, token: "t",
                                         newSessionId: "0d4c9a7e-1111-4222-8333-944455556666", shell: "/bin/zsh")
        #expect(launch.command == "/bin/zsh -l -c 'claude --session-id 0d4c9a7e-1111-4222-8333-944455556666'")
    }

    @Test func resumeWinsOverNewId() {
        let wt = Worktree(projectId: project.id, path: "/tmp/p", branch: "main", isPrimary: true)
        let pane = PaneDescriptor(projectId: project.id, kind: .claude(worktreeId: wt.id, resumeSessionId: "abc"), title: "Claude")
        let launch = TerminalLaunch.make(pane: pane, worktree: wt, remoteHost: nil, token: "t",
                                         newSessionId: "ignored", shell: "/bin/zsh")
        #expect(launch.command == "/bin/zsh -l -c 'claude --resume abc'")
    }
}

@Suite struct TranscriptLocatorTests {
    @Test func findsTranscriptInAnyProjectDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("-Users-j-code-Tether")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("-other"), withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("sess-1.jsonl")
        try Data("{}\n".utf8).write(to: file)
        #expect(TranscriptLocator.find(sessionId: "sess-1", in: root) == file.path)
        #expect(TranscriptLocator.find(sessionId: "missing", in: root) == nil)
        #expect(TranscriptLocator.find(sessionId: "x", in: root.appendingPathComponent("nope")) == nil)
    }
}
