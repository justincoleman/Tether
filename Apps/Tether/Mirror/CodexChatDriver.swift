import Foundation
import TetherCore
import TetherProtocol

/// Owns one native Codex session; terminal-owned sessions must not attach here.
@MainActor
final class CodexChatDriver {
    var onReady: ((SessionID) -> Void)?
    var onState: ((SessionState, AttentionReason?) -> Void)?
    var onEvents: (([MirrorEvent]) -> Void)?
    var onLiveText: ((String?) -> Void)?
    var onPermission: ((PendingPermission) -> Void)?
    var onResolved: ((UUID) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var isReady = false
    private(set) var isWorking = false

    private let directory: String
    private let resumeSessionId: String?
    private let readOnly: Bool
    private let server: CodexAppServer
    private var eventTask: Task<Void, Never>?
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var sessionID: String?
    private var turnID: String?
    private var stopped = false
    private var started = false
    private var emitted: Set<String> = []
    private var liveItem: String?
    private var liveText = ""
    private struct Approval {
        let rpcID: JSONValue
        let questionID: String?
    }
    private var approvals: [UUID: Approval] = [:]

    init(directory: String, executable: String, version: String, resumeSessionId: String?, readOnly: Bool = false, environment: [String: String]? = nil) {
        self.directory = directory
        self.resumeSessionId = resumeSessionId
        self.readOnly = readOnly
        var launchEnvironment = environment ?? ProcessInfo.processInfo.environment
        let executableDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        launchEnvironment["PATH"] = executableDirectory + ":" + (launchEnvironment["PATH"] ?? ToolLocator.systemPath)
        server = CodexAppServer(configuration: .init(workingDirectory: directory, clientVersion: version,
                                                     executableURL: URL(fileURLWithPath: executable), environment: launchEnvironment))
    }

    func start(initialPrompt: String?, review: Bool = false) async {
        guard !started, !stopped else { return }
        started = true
        isWorking = true
        onState?(.working, nil)
        eventTask = Task { [weak self, server] in
            for await event in server.events {
                guard !Task.isCancelled, let self, !self.stopped else { break }
                await self.handle(event)
            }
        }
        do {
            try await server.start()
            try Task.checkCancellation()
            guard !stopped else { return }
            var params: [String: JSONValue] = ["cwd": .string(directory), "approvalPolicy": .string("on-request"),
                                             "sandbox": .string((readOnly || review) ? "read-only" : "workspace-write")]
            if let resumeSessionId { params["threadId"] = .string(resumeSessionId) }
            let result = try await server.request(resumeSessionId == nil ? "thread/start" : "thread/resume", params: .object(params))
            guard !stopped, let thread = result["thread"], let id = thread["id"]?.stringValue else {
                if !stopped { fail("Codex did not return a session identifier.") }
                return
            }
            sessionID = id
            isReady = true
            onReady?(id)
            let history = CodexSessionEvents.history(thread)
            if !history.isEmpty { onEvents?(history) }
            isWorking = false
            if review {
                isWorking = true
                onState?(.working, nil)
                let response = try await server.request("review/start", params: .object([
                    "threadId": .string(id), "delivery": .string("inline"),
                    "target": .object(["type": .string("custom"), "instructions": .string(initialPrompt ?? "Review the current working tree changes for bugs and regressions.")])
                ]))
                if isWorking { turnID = response["turn"]?["id"]?.stringValue }
            } else if let initialPrompt, !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = send(initialPrompt)
            } else {
                onState?(.idle, nil)
            }
        } catch {
            if !stopped { fail(error.localizedDescription) }
        }
    }

    @discardableResult func send(_ text: String) -> Bool {
        guard isReady, !isWorking, !stopped, let sessionID,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        isWorking = true
        onState?(.working, nil)
        operate { [weak self, server] in
            let result = try await server.request("turn/start", params: .object([
                "threadId": .string(sessionID),
                "input": .array([.object(["type": .string("text"), "text": .string(text)])])
            ]))
            if let self, self.isWorking { self.turnID = result["turn"]?["id"]?.stringValue }
        }
        return true
    }

    @discardableResult func interrupt() -> Bool {
        guard isReady, isWorking, !stopped, let sessionID, let turnID else { return false }
        operate { [server] in
            _ = try await server.request("turn/interrupt", params: .object(["threadId": .string(sessionID), "turnId": .string(turnID)]))
        }
        return true
    }

    @discardableResult func resolve(_ id: UUID, decision: PermissionDecision) -> Bool {
        guard !stopped, let approval = approvals[id] else { return false }
        if approval.questionID != nil {
            if case .allowWithInput(let input) = decision,
               case .object(let answers)? = input["answers"], let answer = answers.values.first?.stringValue {
                return self.answer(id, answer: answer)
            }
            switch decision {
            case .deny, .askInTerminal:
                finishApproval(id)
                operate { [server] in try await server.respondError(to: approval.rpcID, message: "User declined to answer.") }
                return true
            default: return false
            }
        }
        guard let result = CodexSessionEvents.approval(decision) else { return false }
        finishApproval(id)
        operate { [server] in try await server.respond(to: approval.rpcID, result: result) }
        return true
    }

    @discardableResult func answer(_ id: UUID, answer: String) -> Bool {
        guard !stopped, let approval = approvals[id], let questionID = approval.questionID,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        finishApproval(id)
        operate { [server] in
            try await server.respond(to: approval.rpcID, result: CodexSessionEvents.answer(questionID: questionID, text: answer))
        }
        return true
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        isReady = false
        isWorking = false
        eventTask?.cancel()
        eventTask = nil
        for operation in operations.values { operation.cancel() }
        operations.removeAll()
        clearApprovals()
        onLiveText?(nil)
        Task { [server] in await server.stop() }
    }

    /// Lets application termination wait until the owned process is stopped.
    func shutdown() async {
        stop()
        await server.stop()
    }

    private func operate(_ body: @escaping @MainActor () async throws -> Void) {
        let id = UUID()
        operations[id] = Task { [weak self] in
            defer { self?.operations.removeValue(forKey: id) }
            do { try await body() } catch {
                if let self, !self.stopped { self.fail(error.localizedDescription) }
            }
        }
    }

    private func handle(_ event: CodexServerEvent) async {
        switch event {
        case .closed(let message):
            isReady = false
            fail(message ?? "Codex disconnected.")
        case .request(let id, let method, let params):
            await permission(id: id, method: method, params: params)
        case .notification(let method, let params):
            if let thread = params["threadId"]?.stringValue, let sessionID, thread != sessionID { return }
            switch method {
            case "item/agentMessage/delta":
                guard let id = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue else { return }
                if liveItem != id { liveItem = id; liveText = "" }
                liveText += delta
                onLiveText?(liveText)
            case "item/started", "item/completed":
                guard let item = params["item"], let id = item["id"]?.stringValue else { return }
                let completed = method == "item/completed"
                let key = id + (completed ? ":complete" : ":start")
                guard emitted.insert(key).inserted else { return }
                if completed, liveItem == id { liveItem = nil; liveText = ""; onLiveText?(nil) }
                let events = CodexSessionEvents.item(item, completed: completed)
                if !events.isEmpty { onEvents?(events) }
            case "turn/started":
                turnID = params["turn"]?["id"]?.stringValue
                isWorking = true
                onState?(.working, nil)
            case "turn/completed":
                turnID = nil
                isWorking = false
                onLiveText?(nil)
                liveItem = nil
                liveText = ""
                clearApprovals()
                let turn = params["turn"]
                if turn?["status"] == .string("failed") {
                    fail(turn?["error"]?["message"]?.stringValue ?? "Codex turn failed.")
                } else {
                    if turn?["status"] == .string("interrupted") {
                        onEvents?([.notice(id: UUID().uuidString, text: "Interrupted", at: Date())])
                    }
                    onState?(.done, nil)
                }
            case "serverRequest/resolved":
                if let rpcID = params["requestId"] {
                    for id in approvals.keys.filter({ approvals[$0]?.rpcID == rpcID }) { finishApproval(id) }
                }
            case "error":
                if params["willRetry"] != .bool(true) { fail(params["error"]?["message"]?.stringValue ?? "Codex reported an error.") }
            default: break
            }
        }
    }

    private func permission(id: JSONValue, method: String, params: JSONValue) async {
        let question: CodexSessionEvents.UserInput?
        let name: String
        let input: JSONValue
        switch method {
        case "item/commandExecution/requestApproval":
            question = nil; name = "Bash"
            input = .object(["command": params["command"] ?? .string("Command approval"), "description": params["reason"] ?? .null])
        case "item/fileChange/requestApproval":
            question = nil; name = "Edit"
            input = .object(["file_path": params["grantRoot"] ?? .string(directory), "description": params["reason"] ?? .null])
        case "item/tool/requestUserInput":
            guard let value = CodexSessionEvents.userInput(params) else {
                try? await server.respondError(to: id, message: "Tether supports one non-secret question at a time.")
                onError?("Codex requested unsupported questions. Ask it to request one non-secret question at a time.")
                return
            }
            question = value; name = AskUserQuestion.toolName; input = value.toolInput
        default:
            try? await server.respondError(to: id, message: "Unsupported app-server request: \(method)")
            onError?("Codex requested an unsupported action: \(method)")
            return
        }
        let request = PendingPermission(sessionId: sessionID ?? params["threadId"]?.stringValue ?? "", paneId: nil,
                                        toolName: name, toolInput: input, suggestions: nil)
        approvals[request.id] = Approval(rpcID: id, questionID: question?.questionID)
        onState?(.needsInput, question == nil ? .permission : .question)
        onPermission?(request)
    }

    private func finishApproval(_ id: UUID) {
        guard approvals.removeValue(forKey: id) != nil else { return }
        onResolved?(id)
        if approvals.isEmpty, isWorking { onState?(.working, nil) }
    }

    private func clearApprovals() {
        let ids = Array(approvals.keys)
        approvals.removeAll()
        for id in ids { onResolved?(id) }
    }

    private func fail(_ message: String) {
        isWorking = false
        onLiveText?(nil)
        clearApprovals()
        onState?(.error, nil)
        onError?(message)
    }
}
