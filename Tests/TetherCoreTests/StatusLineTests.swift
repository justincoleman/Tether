import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

@Suite struct StatusLineTests {
    /// Status line input as Claude Code documents it, with the fields the
    /// user's own status line script reads.
    static let full = #"""
    {"hook_event_name":"Status","session_id":"s1","transcript_path":"/t/s1.jsonl","cwd":"/p",
     "model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},
     "workspace":{"current_dir":"/p","project_dir":"/p"},"version":"2.1.308",
     "cost":{"total_cost_usd":1.2345,"total_duration_ms":45000,"total_api_duration_ms":2300,
             "total_lines_added":156,"total_lines_removed":23},
     "context_window":{"total_input_tokens":174000,"context_window_size":200000},
     "rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1793200000},
                    "seven_day":{"used_percentage":12,"resets_at":1793600000}}}
    """#

    @Test func readsModelCostAndLimits() throws {
        let report = try #require(StatusLineReport(json: Data(Self.full.utf8)))
        #expect(report.sessionId == "s1")
        #expect(report.status == SessionStatus(modelId: "claude-opus-5-5", modelName: "Opus 5.5", costUSD: 1.2345,
                                               contextWindow: 200_000))
        #expect(report.limits?.fiveHour == UsageLimit(usedPercent: 42.5,
                                                      resetsAt: Date(timeIntervalSince1970: 1_793_200_000)))
        #expect(report.limits?.sevenDay?.usedPercent == 12)
    }

    @Test func contextWindowFromSizeOrModelId() throws {
        let sized = #"{"session_id":"s1","model":{"id":"claude-opus-5-5"},"context_window":{"context_window_size":1000000}}"#
        #expect(try #require(StatusLineReport(json: Data(sized.utf8))).status.contextWindow == 1_000_000)
        let suffixed = #"{"session_id":"s1","model":{"id":"claude-opus-5-5[1m]"}}"#
        #expect(try #require(StatusLineReport(json: Data(suffixed.utf8))).status.contextWindow == 1_000_000)
        let plain = #"{"session_id":"s1","model":{"id":"claude-opus-5-5"}}"#
        #expect(try #require(StatusLineReport(json: Data(plain.utf8))).status.contextWindow == nil)
        let usage = ContextUsage(inputTokens: 148_000, contextWindow: 200_000)
        #expect(usage.reported(window: 1_000_000).contextWindow == 1_000_000)
        #expect(usage.reported(window: nil) == usage)
    }

    @Test func savedLimitsRoundTripAndDropExpiredWindows() {
        let now = Date(timeIntervalSince1970: 1_793_300_000)
        let limits = UsageLimits(fiveHour: UsageLimit(usedPercent: 45, resetsAt: now.addingTimeInterval(-60)),
                                 sevenDay: UsageLimit(usedPercent: 32, resetsAt: now.addingTimeInterval(3600)))
        let data = SavedLimits.encode(limits)
        #expect(SavedLimits.decode(data, now: now.addingTimeInterval(-120)) == limits)
        #expect(SavedLimits.decode(data, now: now) == UsageLimits(fiveHour: nil, sevenDay: limits.sevenDay))
        #expect(SavedLimits.decode(data, now: now.addingTimeInterval(7200)) == nil)
        #expect(SavedLimits.decode(nil, now: now) == nil)
        #expect(SavedLimits.decode(Data("junk".utf8), now: now) == nil)
    }

    @Test func apiKeySessionHasNoLimits() throws {
        let json = #"{"session_id":"s1","model":{"id":"claude-sonnet-5-5","display_name":"Sonnet 5.5"},"cost":{"total_cost_usd":0}}"#
        let report = try #require(StatusLineReport(json: Data(json.utf8)))
        #expect(report.limits == nil)
        #expect(report.status.costUSD == 0)
    }

    @Test func isoResetTimeIsAccepted() {
        let limit = StatusLineReport.limit(.object(["used_percentage": .number(5),
                                                    "resets_at": .string("2026-10-28T18:00:00Z")]))
        #expect(limit?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-28T18:00:00Z"))
    }

    @Test func missingSessionIdIsRejected() {
        #expect(StatusLineReport(json: Data(#"{"model":{"id":"x"}}"#.utf8)) == nil)
        #expect(StatusLineReport(json: Data("not json".utf8)) == nil)
    }

    @Test func routerEmitsStatusForPane() async throws {
        let log = EventLog()
        let pane = PaneID()
        let router = HookRouter(token: "secret", registry: SessionRegistry(), broker: PermissionBroker()) {
            await log.append($0)
        }
        let request = HTTPRequest(method: "POST", path: HookSettings.statusPath,
                                  headers: [HookSettings.paneHeader: pane.uuidString,
                                            HookSettings.tokenHeader: "secret"],
                                  body: Data(Self.full.utf8))
        #expect(await router.handle(request) == .empty)
        let events = await log.events
        guard case .status(let paneId, let report)? = events.first else {
            Issue.record("expected a status event"); return
        }
        #expect(paneId == pane)
        #expect(report.status.modelName == "Opus 5.5")
    }

    @Test func routerIgnoresStatusWithWrongToken() async {
        let log = EventLog()
        let router = HookRouter(token: "secret", registry: SessionRegistry(), broker: PermissionBroker()) {
            await log.append($0)
        }
        let request = HTTPRequest(method: "POST", path: HookSettings.statusPath,
                                  headers: [HookSettings.paneHeader: PaneID().uuidString,
                                            HookSettings.tokenHeader: "nope"],
                                  body: Data(Self.full.utf8))
        #expect(await router.handle(request) == .empty)
        #expect(await log.count() == 0)
    }
}

@Suite struct StatusLineSettingsTests {
    private func statusLine(_ user: [String: Any]?) throws -> JSONValue? {
        let data = try HookSettings.settingsJSON(port: 54321, userStatusLine: user)
        return try JSONDecoder().decode(JSONValue.self, from: data)["statusLine"]
    }

    @Test func relayPostsWithPaneAndToken() throws {
        let command = try statusLine(nil)?["command"]?.stringValue ?? ""
        #expect(command.hasPrefix("input=$(cat);"))
        #expect(command.contains(#"-H "X-Tether-Pane: $TETHER_PANE_ID""#))
        #expect(command.contains(#"-H "X-Tether-Token: $TETHER_TOKEN""#))
        #expect(command.contains("--data-binary @- http://127.0.0.1:54321/tether/status"))
        #expect(try statusLine(nil)?["type"]?.stringValue == "command")
    }

    @Test func runsTheUsersCommandAndKeepsItsOptions() throws {
        let user: [String: Any] = ["type": "command", "command": "bash ~/.claude/statusline-command.sh", "padding": 0]
        let line = try statusLine(user)
        let command = line?["command"]?.stringValue ?? ""
        #expect(command.hasSuffix("| {\nbash ~/.claude/statusline-command.sh\n}"))
        #expect(line?["padding"] == .number(0))
    }

    @Test func readsUserStatusLineFromSettings() {
        let settings = #"{"theme":"auto","statusLine":{"type":"command","command":"bash ~/x.sh"}}"#
        #expect(HookSettings.userStatusLine(settings: Data(settings.utf8))?["command"] as? String == "bash ~/x.sh")
        #expect(HookSettings.userStatusLine(settings: Data(#"{"theme":"auto"}"#.utf8)) == nil)
        #expect(HookSettings.userStatusLine(settings: Data("garbage".utf8)) == nil)
    }

    /// The relay is real shell: run it with a fake user command and a dead
    /// port, and check the user's command still gets the JSON on stdin.
    @Test func relayHandsJSONToUserCommand() throws {
        let user: [String: Any] = ["type": "command", "command": "cat # trailing comment"]
        let command = try #require(HookSettings.statusLine(port: 9, user: user)["command"] as? String)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"session_id":"s1"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(printed == #"{"session_id":"s1"}"#)
        #expect(process.terminationStatus == 0)
    }
}

@Suite struct ModelCommandTests {
    @Test func aliasesAndIdsPass() {
        #expect(ModelCommand.text(for: "opus") == "/model opus")
        #expect(ModelCommand.text(for: " sonnet[1m] ") == "/model sonnet[1m]")
        #expect(ModelCommand.text(for: "claude-opus-5-5") == "/model claude-opus-5-5")
    }

    @Test func anythingElseIsRejected() {
        #expect(ModelCommand.text(for: "") == nil)
        #expect(ModelCommand.text(for: "opus\nrm -rf ~") == nil)
        #expect(ModelCommand.text(for: "opus; ls") == nil)
        #expect(ModelCommand.text(for: String(repeating: "a", count: 65)) == nil)
    }
}
