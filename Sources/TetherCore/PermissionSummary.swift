import Foundation

/// Human-readable one-liner for a permission request, shared by the Mac
/// prompt and (phase 5) the phone.
public struct PermissionSummary: Sendable, Equatable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    public static func describe(toolName: String, input: JSONValue?) -> PermissionSummary {
        func field(_ key: String) -> String? { input?[key]?.stringValue }
        switch toolName {
        case "Bash":
            return .init(title: "Run a command", detail: field("command") ?? "")
        case "Edit", "MultiEdit":
            return .init(title: "Edit a file", detail: field("file_path") ?? "")
        case "Write":
            return .init(title: "Write a file", detail: field("file_path") ?? "")
        case "NotebookEdit":
            return .init(title: "Edit a notebook", detail: field("notebook_path") ?? "")
        case "Read":
            return .init(title: "Read a file", detail: field("file_path") ?? "")
        case "WebFetch":
            return .init(title: "Fetch a URL", detail: field("url") ?? "")
        case "WebSearch":
            return .init(title: "Search the web", detail: field("query") ?? "")
        case "Grep":
            return .init(title: "Search files", detail: field("pattern") ?? "")
        case "Glob":
            return .init(title: "Find files", detail: field("pattern") ?? "")
        case "Task", "Agent":
            return .init(title: "Run a subagent", detail: field("description") ?? "")
        case "TodoWrite":
            return .init(title: "Update the task list", detail: "")
        default:
            let json = input?.compactString() ?? ""
            return .init(title: "Use \(toolName)", detail: String(json.prefix(500)))
        }
    }
}
