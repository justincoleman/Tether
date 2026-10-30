import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

@Suite struct ToolLocatorTests {
    let home = "/Users/j"

    @Test func probeOutputIgnoresBannersAndEscapeCodes() {
        let output = """
        Last login: Fri Oct 30 14:47:33 on ttys000
        \u{1b}]7;file:///Users/j\u{07}
        \u{1b}[?2004h__TETHER_PROBE__PATH=/Users/j/.local/bin:/opt/homebrew/bin:/usr/bin:/bin
        __TETHER_PROBE__claude=/Users/j/.local/bin/claude
        __TETHER_PROBE__codex=
        """
        let parsed = ToolLocator.parseProbe(output, home: home)
        #expect(parsed.path == "/Users/j/.local/bin:/opt/homebrew/bin:/usr/bin:/bin")
        #expect(parsed.tools == ["claude": "/Users/j/.local/bin/claude"])
    }

    @Test func aliasesResolveToTheirTargetAndFunctionsDont() {
        // zsh and bash print an alias like this from `command -v`.
        #expect(ToolLocator.executablePath(fromCommandV: "alias claude='~/.claude/local/claude'", home: home)
                == "/Users/j/.claude/local/claude")
        #expect(ToolLocator.executablePath(fromCommandV: "alias claude=\"$HOME/.claude/local/claude --verbose\"", home: home)
                == "/Users/j/.claude/local/claude")
        #expect(ToolLocator.executablePath(fromCommandV: "alias claude=/opt/claude", home: home) == "/opt/claude")
        #expect(ToolLocator.executablePath(fromCommandV: "claude", home: home) == nil)
        #expect(ToolLocator.executablePath(fromCommandV: "", home: home) == nil)
        #expect(ToolLocator.executablePath(fromCommandV: "alias claude='npx claude'", home: home) == nil)
    }

    @Test func probeScriptMarksEveryLine() {
        let script = ToolLocator.probeScript(tools: ["claude", "codex"])
        #expect(script.contains("__TETHER_PROBE__PATH=%s"))
        #expect(script.contains("\"$(command -v claude 2>/dev/null)\""))
        #expect(script.contains("__TETHER_PROBE__codex=%s"))
    }

    @Test func mergePrefersOverrideThenShellThenCommonFolders() {
        let exists: Set<String> = [
            "/Users/j/bin/my-claude", "/Users/j/.local/bin/claude",
            "/opt/homebrew/bin/claude", "/opt/homebrew/bin/codex",
        ]
        let probe = "__TETHER_PROBE__PATH=/usr/bin:/bin\n__TETHER_PROBE__claude=/Users/j/.local/bin/claude\n"
        func merge(_ overrides: [String: String], _ probes: [String]) -> ToolPaths {
            ToolLocator.merge(tools: ["claude", "codex"], probes: probes, home: home, overrides: overrides,
                              isExecutable: { exists.contains($0) }, listDirectory: { _ in [] })
        }
        let picked = merge(["claude": "/Users/j/bin/my-claude"], [probe])
        #expect(picked.path(of: "claude") == "/Users/j/bin/my-claude")
        let shell = merge([:], [probe])
        #expect(shell.path(of: "claude") == "/Users/j/.local/bin/claude")
        // Codex wasn't in the probe: found in a common folder.
        #expect(shell.path(of: "codex") == "/opt/homebrew/bin/codex")
        #expect(shell.shellPath == "/usr/bin:/bin")
        // No shell answered: ~/.local/bin is checked before Homebrew.
        let noShell = merge([:], [])
        #expect(noShell.path(of: "claude") == "/Users/j/.local/bin/claude")
        #expect(noShell.shellPath == nil)
    }

    @Test func staleOverrideAndMissingProbeResultFallThrough() {
        let probe = "__TETHER_PROBE__claude=/gone/claude\n"
        let paths = ToolLocator.merge(tools: ["claude"], probes: [probe], home: home,
                                      overrides: ["claude": "/also/gone"],
                                      isExecutable: { $0 == "/usr/local/bin/claude" }, listDirectory: { _ in [] })
        #expect(paths.path(of: "claude") == "/usr/local/bin/claude")
        let none = ToolLocator.merge(tools: ["claude"], probes: [], home: home, overrides: [:],
                                     isExecutable: { _ in false }, listDirectory: { _ in [] })
        #expect(none.path(of: "claude") == nil)
    }

    @Test func nvmVersionsAreSearchedNewestFirst() {
        let dirs = ToolLocator.candidateDirectories(home: home) { path in
            path == "/Users/j/.nvm/versions/node" ? ["v18.20.1", "v22.3.0", "v9.11.2", "v22.11.0"] : []
        }
        let nvm = dirs.filter { $0.contains(".nvm") }
        #expect(nvm == ["/Users/j/.nvm/versions/node/v22.11.0/bin", "/Users/j/.nvm/versions/node/v22.3.0/bin",
                        "/Users/j/.nvm/versions/node/v18.20.1/bin", "/Users/j/.nvm/versions/node/v9.11.2/bin"])
        #expect(dirs.first == "/Users/j/.local/bin")
    }

    @Test func launchPathAddsToolFolders() {
        let paths = ToolPaths(executables: ["claude": "/Users/j/.local/bin/claude", "codex": "/usr/bin/codex"],
                              shellPath: nil)
        #expect(paths.launchPath(inherited: "/usr/bin:/bin:/usr/sbin:/sbin")
                == "/usr/bin:/bin:/usr/sbin:/sbin:/Users/j/.local/bin")
        let shell = ToolPaths(executables: ["claude": "/Users/j/.local/bin/claude"],
                              shellPath: "/Users/j/.local/bin:/usr/bin")
        #expect(shell.launchPath(inherited: "/usr/bin") == "/Users/j/.local/bin:/usr/bin")
    }

    @Test func claudeLaunchUsesTheAbsolutePathAndShellPath() {
        let project = Project(name: "p", path: "/tmp/p")
        let wt = Worktree(projectId: project.id, path: "/tmp/p", branch: "main", isPrimary: true)
        let pane = PaneDescriptor(projectId: project.id, kind: .claude(worktreeId: wt.id, resumeSessionId: "abc"), title: "Claude")
        let launch = TerminalLaunch.make(pane: pane, worktree: wt, remoteHost: nil, token: "t", shell: "/bin/zsh",
                                         claudeExecutable: "/Users/j/.local/bin/claude",
                                         searchPath: "/Users/j/.local/bin:/usr/bin")
        #expect(launch.command == "/bin/zsh -l -c '/Users/j/.local/bin/claude --resume abc'")
        #expect(launch.environment["PATH"] == "/Users/j/.local/bin:/usr/bin")
        let shellPane = PaneDescriptor(projectId: project.id, kind: .shell(cwd: "/tmp/p"), title: "Shell")
        let shell = TerminalLaunch.make(pane: shellPane, worktree: nil, remoteHost: nil, token: "t",
                                        searchPath: "/Users/j/.local/bin:/usr/bin")
        #expect(shell.environment["PATH"] == nil)
    }

    @Test func locateRunsARealShell() async {
        // A long timeout: this runs beside a hundred other tests on a busy machine.
        let paths = await ToolLocator.locate(["sh", "tether-no-such-tool-xyz"], shell: "/bin/sh",
                                             home: "/nonexistent", timeout: 60)
        #expect(paths.path(of: "sh")?.hasSuffix("/sh") == true)
        #expect(paths.path(of: "tether-no-such-tool-xyz") == nil)
        #expect(paths.shellPath?.isEmpty == false)
    }
}
