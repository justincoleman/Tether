import Foundation
import Testing
import TetherProtocol
@testable import TetherCore

@Suite struct AgentTransferTests {
    @Test func reviewIsScopedAndPublicContextBounded() {
        let at = Date()
        let items: [TranscriptItem] = [.user(id: "u", text: String(repeating: "x", count: 30_000), at: at),
                                       .steps(id: "tools", steps: [.init(id: "secret", name: "Bash", summary: "private tool output", at: at)]),
                                       .assistant(id: "a", text: "Public reply", at: at)]
        let text = AgentTransferMessage.compose(kind: .review, source: .claude, directory: "/repo/worktree",
                                                base: "origin/main", files: ["file.swift"], items: items)
        #expect(text.contains("/repo/worktree")); #expect(text.contains("origin/main"))
        #expect(text.contains("Public reply")); #expect(!text.contains("private tool output"))
        #expect(text.count < 14_000); #expect(text.contains("Do not edit"))
    }
    @Test func transferGateRequiresSourceReady() {
        #expect(!AgentTransferMessage.canStart(state: .working, attention: nil))
        #expect(!AgentTransferMessage.canStart(state: .needsInput, attention: .permission))
        #expect(AgentTransferMessage.canStart(state: .done, attention: nil))
        #expect(AgentTransferMessage.canStart(state: .needsInput, attention: .question))
    }
}
