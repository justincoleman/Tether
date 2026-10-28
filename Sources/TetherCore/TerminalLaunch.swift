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
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        claudeExecutable: String = "claude"
    ) -> TerminalLaunch {
        let env = [paneEnvKey: pane.id.uuidString, tokenEnvKey: token]
        switch pane.kind {
        case .claude(_, let resume):
            var parts = [claudeExecutable]
            if let hookSettingsPath { parts += ["--settings", hookSettingsPath] }
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
