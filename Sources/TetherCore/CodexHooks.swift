import Foundation

/// The hooks Tether hands every `codex` it launches, as `-c` config overrides.
/// They apply to that run only and never touch `~/.codex/config.toml`.
///
/// Codex runs only command hooks, so each one is a `curl` that posts the hook's
/// JSON to the same HookServer paths Claude's hooks use. Codex asks the user to
/// review new or changed hooks once (`/hooks`) and remembers them by hash, so
/// the arguments must be byte-identical on every launch: the port, pane and
/// token come from the pty's environment, never from the command text.
/// See docs/HOOKS.md, "Codex".
public enum CodexHooks {
    /// The hook server's port, set in every Codex pty.
    public static let portEnvKey = "TETHER_HOOK_PORT"

    /// Events that only report state, in a fixed order so the arguments never change.
    public static let observedEvents = [
        "SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "Interrupt", "SessionEnd",
    ]
    static let observedTimeoutSeconds = 10
    /// Codex clamps SessionEnd hooks to 3 seconds and warns about anything longer.
    static let sessionEndTimeoutSeconds = 3

    /// `-c key=value` pairs to put before any subcommand.
    public static func configArguments() -> [String] {
        var args: [String] = []
        for event in observedEvents {
            let timeout = event == "SessionEnd" ? sessionEndTimeoutSeconds : observedTimeoutSeconds
            args += ["-c", override(event: event, command: observeCommand(), timeout: timeout)]
        }
        args += ["-c", override(event: "PermissionRequest", command: permissionCommand(),
                                timeout: HookSettings.permissionTimeoutSeconds)]
        return args
    }

    /// `hooks.<Event>=[{hooks=[{type="command",command="…",timeout=N}]}]`, the
    /// shape captured working with Codex 0.164.
    static func override(event: String, command: String, timeout: Int) -> String {
        "hooks.\(event)=[{hooks=[{type=\"command\",command=\(tomlString(command)),timeout=\(timeout)}]}]"
    }

    /// Posts stdin to Tether and prints nothing: no output means no decision.
    /// Always exits 0, so a missing Tether never blocks Codex.
    static func observeCommand() -> String {
        curl(path: HookSettings.hookPath, maxTime: 2) + " >/dev/null 2>&1 || true"
    }

    /// Posts the request and prints Tether's answer, which has the same
    /// `hookSpecificOutput.decision` shape for Codex as for Claude. An empty
    /// answer (no decision, or Tether gone) leaves Codex to ask in the terminal.
    static func permissionCommand() -> String {
        curl(path: HookSettings.permissionPath, maxTime: HookSettings.permissionTimeoutSeconds - 5)
            + " 2>/dev/null || true"
    }

    static func curl(path: String, maxTime: Int) -> String {
        let pane = TerminalLaunch.paneEnvKey, token = TerminalLaunch.tokenEnvKey
        return "curl -s --max-time \(maxTime) -X POST"
            + " -H \"Content-Type: application/json\" -H \"Expect:\""
            + " -H \"\(HookSettings.paneHeader): $\(pane)\" -H \"\(HookSettings.tokenHeader): $\(token)\""
            + " --data-binary @- \"http://127.0.0.1:$\(portEnvKey)\(path)\""
    }

    /// A TOML basic string.
    static func tomlString(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }
}
