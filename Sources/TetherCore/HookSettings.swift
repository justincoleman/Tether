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

    public static func settingsJSON(port: UInt16) throws -> Data {
        var hooks: [String: Any] = [:]
        for event in observedEvents {
            hooks[event] = [["hooks": [handler(port: port, path: hookPath, timeout: observedTimeoutSeconds)]]]
        }
        for event in commandEvents {
            hooks[event] = [["hooks": [commandHandler(port: port, path: hookPath)]]]
        }
        hooks["PermissionRequest"] = [["hooks": [handler(port: port, path: permissionPath,
                                                          timeout: permissionTimeoutSeconds)]]]
        return try JSONSerialization.data(withJSONObject: ["hooks": hooks],
                                          options: [.prettyPrinted, .sortedKeys])
    }

    public static func write(port: UInt16, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try settingsJSON(port: port).write(to: url, options: .atomic)
    }
}
