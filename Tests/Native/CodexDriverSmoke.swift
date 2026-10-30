import Foundation
import TetherCore
import TetherProtocol

@main struct Smoke {
    @MainActor static func main() async throws {
        let driver = CodexChatDriver(directory: "/tmp", executable: CommandLine.arguments[1], version: "test", resumeSessionId: nil)
        var ready = false
        var events: [MirrorEvent] = []
        var live: [String?] = []
        var errors: [String] = []
        var approvals = 0
        var startupIdleCallbacks = 0
        driver.onReady = { id in precondition(id == "native-test" && driver.isReady); ready = true }
        driver.onEvents = { batch in precondition(ready); events += batch }
        driver.onState = { state, _ in
            if state == .idle {
                precondition(ready)
                startupIdleCallbacks += 1
                _ = driver.send("queued")
            }
        }
        driver.onLiveText = { live.append($0) }
        driver.onError = { errors.append($0) }
        driver.onPermission = { permission in
            approvals += 1
            precondition(driver.resolve(permission.id, decision: permission.toolName == AskUserQuestion.toolName ? .askInTerminal : .allow))
        }
        await driver.start(initialPrompt: "test")
        precondition(driver.isReady && startupIdleCallbacks == 0)
        precondition(!driver.send("busy"))
        for _ in 0..<200 { if !driver.isWorking { break }; try await Task.sleep(for: .milliseconds(10)) }
        precondition(!driver.isWorking && approvals == 1 && errors.isEmpty)
        precondition(live.contains { $0 == "Done" })
        precondition(events.contains { if case .assistantText(_, "Done", _) = $0 { true } else { false } })
        precondition(events.count == 2)
        precondition(driver.send("hang"))
        var interrupted = false
        for _ in 0..<200 {
            if driver.interrupt() { interrupted = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(interrupted)
        for _ in 0..<200 { if !driver.isWorking { break }; try await Task.sleep(for: .milliseconds(10)) }
        precondition(!driver.isWorking)
        precondition(driver.send("question"))
        for _ in 0..<200 { if !driver.isWorking { break }; try await Task.sleep(for: .milliseconds(10)) }
        precondition(!driver.isWorking && approvals == 2 && errors.isEmpty)
        await driver.shutdown()
        precondition(!driver.isReady && !driver.send("after close"))
        let review = CodexChatDriver(directory: "/tmp", executable: CommandLine.arguments[1], version: "test", resumeSessionId: nil)
        var readOnly = false
        review.onEvents = { batch in readOnly = batch.contains { if case .assistantText(_, "sandbox:read-only", _) = $0 { true } else { false } } }
        await review.start(initialPrompt: "Review", review: true)
        precondition(readOnly)
        await review.shutdown()
        try await Task.sleep(for: .milliseconds(50))
        print("PASS: ready before history and idle; send/busy; approval; question fallback declined; streamed/final answer; interrupt; close; read-only review")
    }
}
