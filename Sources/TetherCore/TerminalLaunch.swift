import Foundation
import TetherProtocol

/// Everything needed to spawn a pty for a pane. Pure value, so it is unit-tested
/// on Linux and the Mac app only has to hand it to libghostty.
public struct TerminalLaunch: Hashable, Sendable {
    public var command: String?
    public var workingDirectory: String?
    public var environment: [String: String]

    public static let paneEnvKey = "TETHER_PANE_ID"
    public static let tokenEnvKey = "TETHER_TOKEN"
    /// A quick action's command, read by the wrapper script so it needs no quoting.
    public static let runEnvKey = "TETHER_RUN"

    public init(command: String?, workingDirectory: String?, environment: [String: String]) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// Builds the launch for a pane. `token` is the per-launch secret the hook
    /// server (phase 2) checks; `shell` is the user's login shell.
    public static func make(
        pane: PaneDescriptor,
        worktree: Worktree?,
        remoteHost: RemoteHost?,
        token: String,
        hookSettingsPath: String? = nil,
        newSessionId: SessionID? = nil,
        initialPrompt: String? = nil,
        permissionMode: String? = nil,
        hookPort: UInt16? = nil,
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        claudeExecutable: String = "claude",
        codexExecutable: String = "codex"
    ) -> TerminalLaunch {
        let env = [paneEnvKey: pane.id.uuidString, tokenEnvKey: token]
        switch pane.kind {
        case .codex(_, let resume):
            var parts = [codexExecutable]
            var codexEnv = env
            if let hookPort {
                parts += CodexHooks.configArguments()
                codexEnv[CodexHooks.portEnvKey] = String(hookPort)
            }
            if let resume, !resume.isEmpty {
                parts += ["resume", resume]
            } else if let prompt = initialPrompt.map(promptText),
                      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // `codex "<prompt>"` starts on a task, like `claude "<prompt>"`.
                parts.append(prompt.hasPrefix("-") ? " " + prompt : prompt)
            }
            return TerminalLaunch(
                command: loginShellCommand(shell: shell, parts),
                workingDirectory: worktree?.path,
                environment: codexEnv)
        case .claude(_, let resume):
            var parts = [claudeExecutable]
            if let hookSettingsPath { parts += ["--settings", hookSettingsPath] }
            if let permissionMode, launchablePermissionModes.contains(permissionMode) {
                parts += ["--permission-mode", permissionMode]
            }
            if let resume, !resume.isEmpty {
                parts += ["--resume", resume]
            } else if let newSessionId {
                // Choosing the id up front lets Tether find the transcript
                // before any hook fires.
                parts += ["--session-id", newSessionId]
            }
            // A new session can start on a task: `claude "<prompt>"`. Typing it
            // in later would race the TUI's startup.
            if resume == nil || resume?.isEmpty == true,
               let prompt = initialPrompt.map(promptText), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A leading dash would be read as a flag.
                parts.append(prompt.hasPrefix("-") ? " " + prompt : prompt)
            }
            return TerminalLaunch(
                command: loginShellCommand(shell: shell, parts),
                workingDirectory: worktree?.path,
                environment: env)
        case .shell(let cwd):
            return TerminalLaunch(command: nil, workingDirectory: cwd, environment: env)
        case .command(let cwd, let command):
            var withCommand = env
            withCommand[runEnvKey] = command
            return TerminalLaunch(command: quickActionCommand(shell: shell),
                                  workingDirectory: cwd, environment: withCommand)
        case .ssh:
            guard let remoteHost else {
                return TerminalLaunch(command: nil, workingDirectory: nil, environment: env)
            }
            return TerminalLaunch(
                command: loginShellCommand(shell: shell, ["ssh", "-t", remoteHost.sshTarget]),
                workingDirectory: nil,
                environment: env)
        }
    }

    /// Runs `argv` through the user's login shell so PATH additions from
    /// .zprofile (where `claude` usually lives) apply. The pty stays open after
    /// exit because the surface is created with `waitAfterCommand`.
    static func loginShellCommand(shell: String, _ argv: [String]) -> String {
        let joined = argv.map(shellQuote).joined(separator: " ")
        return "\(shell) -l -c \(shellQuote(joined))"
    }

    /// Runs `$TETHER_RUN` in an interactive login shell, so PATH set up in
    /// .zshrc (nvm, rbenv) applies, then stays in a shell in the same folder.
    /// The outer `sh` traps Ctrl-C so stopping a dev server doesn't close the tab.
    static func quickActionCommand(shell: String) -> String {
        let s = shellQuote(shell)
        let script = "trap : INT; \(s) -ilc \"$\(runEnvKey)\"; exec \(s) -l"
        return "/bin/sh -c \(shellQuote(script))"
    }

    /// Modes the phone may start a tab in. `dontAsk` and `bypassPermissions`
    /// are left out on purpose: neither should be one tap away on a phone.
    public static let launchablePermissionModes: Set<String> = ["default", "acceptEdits", "plan", "auto"]

    /// POSIX single-quote escaping.
    public static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@".contains($0) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Text to paste into a Claude Code prompt. Trailing newlines are stripped
    /// because submit is a separate Enter keypress, not pasted characters.
    public static func promptText(_ text: String) -> String {
        var t = Substring(text)
        while let last = t.last, last == "\n" || last == "\r" { t.removeLast() }
        return String(t)
    }
}
