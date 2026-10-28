import Foundation

/// The settings file Tether passes to every `claude` it launches via
/// `--settings`. Hooks there apply only to Tether's sessions, merge with the
/// user's own hooks (list keys merge across settings sources), and never touch
/// `~/.claude/settings.json`.
public enum HookSettings {
    public static let paneHeader = "X-Tether-Pane"
    public static let tokenHeader = "X-Tether-Token"
    public static let hookPath = "/tether/hook"
    public static let permissionPath = "/tether/permission"
    public static let statusPath = "/tether/status"

    /// Events that only report state. HTTP hooks cannot be `async`, so the
    /// server answers these immediately and the timeout is short.
    public static let observedEvents = [
        "UserPromptSubmit", "Stop", "StopFailure",
        "Notification", "SessionEnd", "PostToolUse",
    ]
    /// Claude Code runs only command (and MCP tool) hooks on SessionStart, so
    /// this one is a `curl` that posts the same JSON with the same headers.
    /// Without it a freshly launched tab has no state until its first prompt.
    public static let commandEvents = ["SessionStart"]
    public static let observedTimeoutSeconds = 10
    /// Claude Code waits this long for a permission answer before falling back
    /// to its own prompt. The broker gives up a little earlier.
    public static let permissionTimeoutSeconds = 600

    static func handler(port: UInt16, path: String, timeout: Int) -> [String: Any] {
        [
            "type": "http",
            "url": "http://127.0.0.1:\(port)\(path)",
            "timeout": timeout,
            "headers": [
                paneHeader: "$\(TerminalLaunch.paneEnvKey)",
                tokenHeader: "$\(TerminalLaunch.tokenEnvKey)",
            ],
            "allowedEnvVars": [TerminalLaunch.paneEnvKey, TerminalLaunch.tokenEnvKey],
        ]
    }

    /// Posts the hook's stdin to Tether. Silent and always exit 0: SessionStart
    /// stdout becomes Claude's context, and a failure must not block startup.
    static func commandHandler(port: UInt16, path: String) -> [String: Any] {
        let pane = TerminalLaunch.paneEnvKey, token = TerminalLaunch.tokenEnvKey
        let command = "curl -s -o /dev/null --max-time 3 -X POST"
            + " -H 'Content-Type: application/json' -H 'Expect:'"
            + " -H \"\(paneHeader): $\(pane)\" -H \"\(tokenHeader): $\(token)\""
            + " --data-binary @- http://127.0.0.1:\(port)\(path) || true"
        return ["type": "command", "command": command, "timeout": 5]
    }

    /// The user's `statusLine` from their own settings, if it runs a command.
    /// Tether's `--settings` replaces it, so the relay runs it in turn.
    public static func userStatusLine(settings: Data) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
              let statusLine = root["statusLine"] as? [String: Any],
              statusLine["type"] as? String == "command",
              let command = statusLine["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return statusLine
    }

    /// A status line that posts Claude Code's JSON to Tether, then hands the
    /// same JSON to the user's own status line command so the terminal looks
    /// as it did. Without one it prints nothing. The post is quick (loopback)
    /// and never fails the status line.
    static func statusLine(port: UInt16, user: [String: Any]?) -> [String: Any] {
        let pane = TerminalLaunch.paneEnvKey, token = TerminalLaunch.tokenEnvKey
        var command = "input=$(cat); printf '%s' \"$input\" | curl -s -o /dev/null --max-time 1 -X POST"
            + " -H 'Content-Type: application/json' -H 'Expect:'"
            + " -H \"\(paneHeader): $\(pane)\" -H \"\(tokenHeader): $\(token)\""
            + " --data-binary @- http://127.0.0.1:\(port)\(statusPath) >/dev/null 2>&1"
        var result = user ?? ["type": "command"]
        if let userCommand = user?["command"] as? String {
            // Braces keep `a; b` or `a && b` reading stdin as one command; the
            // newline keeps a trailing comment from swallowing the brace.
            command += "; printf '%s' \"$input\" | {\n\(userCommand)\n}"
        }
        result["command"] = command
        return result
    }

    public static func settingsJSON(port: UInt16, userStatusLine: [String: Any]? = nil) throws -> Data {
        var hooks: [String: Any] = [:]
        for event in observedEvents {
            hooks[event] = [["hooks": [handler(port: port, path: hookPath, timeout: observedTimeoutSeconds)]]]
        }
        for event in commandEvents {
            hooks[event] = [["hooks": [commandHandler(port: port, path: hookPath)]]]
        }
        hooks["PermissionRequest"] = [["hooks": [handler(port: port, path: permissionPath,
                                                          timeout: permissionTimeoutSeconds)]]]
        let root: [String: Any] = ["hooks": hooks, "statusLine": statusLine(port: port, user: userStatusLine)]
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    public static func write(port: UInt16, to url: URL, userStatusLine: [String: Any]? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try settingsJSON(port: port, userStatusLine: userStatusLine).write(to: url, options: .atomic)
    }
}
