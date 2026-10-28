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
        "SessionStart", "UserPromptSubmit", "Stop", "StopFailure",
        "Notification", "SessionEnd", "PostToolUse",
    ]
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

    public static func settingsJSON(port: UInt16) throws -> Data {
        var hooks: [String: Any] = [:]
        for event in observedEvents {
            hooks[event] = [["hooks": [handler(port: port, path: hookPath, timeout: observedTimeoutSeconds)]]]
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
