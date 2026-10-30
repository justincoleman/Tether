import Foundation
import Testing
import TetherProtocol
@testable import TetherCore

@Suite struct CodexSessionEventsTests {
    @Test func publicMessagesExcludeReasoningAndHookPrompts() {
        let date = Date(timeIntervalSince1970: 1)
        let message: JSONValue = .object(["id": .string("a"), "type": .string("agentMessage"), "text": .string("Public answer")])
        #expect(CodexSessionEvents.item(message, completed: false).isEmpty)
        #expect(CodexSessionEvents.item(message, completed: true, at: date) == [.assistantText(id: "a", text: "Public answer", at: date)])
        for type in ["reasoning", "hookPrompt", "collabAgentToolCall"] {
            #expect(CodexSessionEvents.item(.object(["id": .string("hidden"), "type": .string(type), "text": .string("private")]), completed: true).isEmpty)
        }
    }

    @Test func toolsHaveMatchedIDsAndFailureStatus() {
        let date = Date(timeIntervalSince1970: 1)
        let command: JSONValue = .object(["id": .string("cmd"), "type": .string("commandExecution"), "command": .string("false"), "exitCode": .number(1), "aggregatedOutput": .string("failed")])
        #expect(CodexSessionEvents.item(command, completed: false, at: date) == [.toolUse(id: "cmd", name: "Bash", summary: "false", at: date)])
        #expect(CodexSessionEvents.item(command, completed: true, at: date) == [.toolResult(id: "cmd:result", toolUseId: "cmd", summary: "failed", isError: true, at: date)])
        let thread: JSONValue = .object(["turns": .array([.object(["items": .array([command])])])])
        #expect(CodexSessionEvents.history(thread, at: date).count == 2)
    }

    @Test func singleQuestionPreservesPhoneOptionsAndAnswerID() {
        let params: JSONValue = .object(["questions": .array([.object(["id": .string("qid"), "header": .string("Choice"), "question": .string("Which?"), "options": .array([.object(["label": .string("First"), "description": .string("One")])])])])])
        let question = CodexSessionEvents.userInput(params)
        #expect(question?.questionID == "qid")
        #expect(AskUserQuestion.prompt(from: question?.toolInput)?.options.first?.label == "First")
        #expect(CodexSessionEvents.answer(questionID: "qid", text: "First")["answers"]?["qid"]?["answers"] == .array([.string("First")]))
        #expect(CodexSessionEvents.userInput(.object(["questions": .array([params, params])])) == nil)
    }

    @Test func largeToolOutputUsesBoundedTailForRemoteViewers() {
        let lines = (0..<20).map { "line\($0):" + String(repeating: "x", count: 1_000) }
        let command: JSONValue = .object([
            "id": .string("large"), "type": .string("commandExecution"),
            "aggregatedOutput": .string(lines.joined(separator: "\n"))
        ])
        guard case .toolResult(_, _, let summary, _, _)? = CodexSessionEvents.item(command, completed: true).first else {
            Issue.record("Expected a tool result")
            return
        }
        #expect(summary.split(separator: "\n").count == 6)
        #expect(summary.hasPrefix("line14:"))
        #expect(summary.contains("line19:"))
        #expect(summary.count <= 1_805)
    }

    @Test func approvalMappingNeverTreatsModifiedInputAsApproval() {
        #expect(CodexSessionEvents.approval(.allow)?["decision"] == .string("accept"))
        #expect(CodexSessionEvents.approval(.allowAlways)?["decision"] == .string("acceptForSession"))
        #expect(CodexSessionEvents.approval(.deny(message: nil))?["decision"] == .string("decline"))
        #expect(CodexSessionEvents.approval(.allowWithInput(.null)) == nil)
    }
}
