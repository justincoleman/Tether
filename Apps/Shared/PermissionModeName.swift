import Foundation

/// Claude Code's permission modes as the phone shows them. The Mac only
/// launches the ones in `launchable` (TerminalLaunch.launchablePermissionModes).
enum PermissionModeName {
    static let launchable = ["default", "acceptEdits", "plan", "auto"]

    static func label(_ mode: String) -> String {
        switch mode {
        case "default": "Manual"
        case "acceptEdits": "Accept edits"
        case "plan": "Plan"
        case "auto": "Auto"
        case "dontAsk": "Don't ask"
        case "bypassPermissions": "Bypass permissions"
        default: mode
        }
    }

    static func explanation(_ mode: String?) -> String {
        switch mode {
        case nil: "Uses the default mode from Claude Code's settings on the Mac."
        case "default": "Asks before every command and edit. Prompts come to this phone."
        case "acceptEdits": "Edits files without asking; asks before commands."
        case "plan": "Researches and proposes a plan without changing anything."
        case "auto": "Runs without routine prompts; only risky actions ask."
        default: ""
        }
    }

    static func symbol(_ mode: String) -> String {
        switch mode {
        case "default": "hand.raised"
        case "acceptEdits": "pencil"
        case "plan": "list.bullet.clipboard"
        case "auto": "bolt"
        case "bypassPermissions": "exclamationmark.shield"
        default: "questionmark.circle"
        }
    }
}
