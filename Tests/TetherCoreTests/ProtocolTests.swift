import Foundation
import TetherCore
import Testing
import TetherProtocol

@Suite struct ProtocolTests {
    @Test func macMessageRoundTrips() throws {
        let pane = UUID(), project = UUID()
        let snapshot = Snapshot(
            macName: "Mac mini",
            projects: [ProjectSummary(id: project, name: "Tether", branch: "main")],
            sessions: [SessionSummary(id: pane, projectId: project, sessionId: "s1", title: "Claude",
                                      state: .needsInput, attention: .permission, queued: 1,
                                      status: SessionStatus(modelId: "claude-opus-5-5", modelName: "Opus 5.5",
                                                            costUSD: 1.25))],
            permissions: [PermissionRequested(id: UUID(), paneId: pane, sessionId: "s1", toolName: "Bash",
                                              title: "Run a command", detail: "npm test")],
            limits: UsageLimits(fiveHour: UsageLimit(usedPercent: 42, resetsAt: Date(timeIntervalSince1970: 1_793_200_000)),
                                sevenDay: nil))
        let data = try WireCodec.encoder().encode(MacMessage.snapshot(snapshot))
        let decoded = try WireCodec.decoder().decode(MacMessage.self, from: data)
        guard case .snapshot(let s) = decoded else {
            Issue.record("wrong case"); return
        }
        #expect(s == snapshot)
    }

    @Test func projectIconsRoundTrip() throws {
        let id = UUID()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
        let data = try WireCodec.encoder().encode(MacMessage.projectIcons([ProjectIcon(id: id, png: png)]))
        guard case .projectIcons(let icons) = try WireCodec.decoder().decode(MacMessage.self, from: data) else {
            Issue.record("wrong case"); return
        }
        #expect(icons == [ProjectIcon(id: id, png: png)])
    }

    @Test func transcriptRoundTrips() throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let original = MacMessage.transcript(sessionId: "s1", events: [
            .userText(id: "u1", text: "hi", at: at),
            .toolUse(id: "t1", name: "Bash", summary: "ls", at: at),
            .toolDetail(toolUseId: "t1", file: "/p/a.swift", removed: ["x"], added: ["y"], at: at),
        ], reset: true)
        let data = try WireCodec.encoder().encode(original)
        guard case .transcript(let id, let events, let reset) = try WireCodec.decoder().decode(MacMessage.self, from: data) else {
            Issue.record("wrong case"); return
        }
        #expect(id == "s1" && reset && events.count == 3)
        var model = TranscriptModel()
        model.apply(events)
        #expect(model.items.count == 2)
    }

    @Test func transcriptPreviewIsLatestMessageOnOneLine() {
        let at = Date(timeIntervalSince1970: 0)
        var model = TranscriptModel()
        #expect(model.preview() == nil)
        model.apply([
            .userText(id: "u1", text: "Fix the login bug", at: at),
            .assistantText(id: "a1", text: "## Done\n\nI **fixed** it in\n`Login.swift`.", at: at),
            .toolUse(id: "t1", name: "Bash", summary: "ls", at: at),
        ])
        #expect(model.preview() == "Done I fixed it in Login.swift.")
        model.apply(.userText(id: "u2", text: String(repeating: "a", count: 300), at: at))
        let long = model.preview(limit: 20)!
        #expect(long.count == 20 && long.hasPrefix("You: aaa") && long.hasSuffix("…"))
    }

    @Test func phoneMessageRoundTrips() throws {
        let pane = UUID()
        let request = UUID()
        let original = PhoneMessage.sendMessage(requestId: request, paneId: pane, text: "ship it")
        let data = try WireCodec.encoder().encode(original)
        let decoded = try WireCodec.decoder().decode(PhoneMessage.self, from: data)
        guard case .sendMessage(let requestId, let id, let text) = decoded else {
            Issue.record("wrong case"); return
        }
        #expect(id == pane)
        #expect(requestId == request)
        #expect(text == "ship it")
    }

    @Test func sendReceiptIdentifiesTheExactReply() throws {
        let request = UUID(), pane = UUID()
        let encoded = try WireCodec.encoder().encode(MacMessage.sendResult(paneId: pane, outcome: "queued", requestId: request))
        guard case .sendResult(let decodedPane, let outcome, let decodedRequest) = try WireCodec.decoder().decode(MacMessage.self, from: encoded) else {
            Issue.record("wrong case"); return
        }
        #expect(decodedPane == pane && decodedRequest == request && outcome == "queued")
    }

    @Test func changesAndDiffsRoundTrip() throws {
        let request = UUID()
        let file = ChangedFile(path: "a.swift", kind: .modified, additions: 1, deletions: 0)
        let snapshot = ChangesSnapshot(branch: "feature", commitShort: "abc1234", upstream: nil, ahead: 1, behind: 0,
                                       baseRef: "origin/main", mergeBase: "abc", files: [file], commits: [])
        let data = try WireCodec.encoder().encode(MacMessage.changes(requestId: request, snapshot: snapshot, error: nil))
        guard case .changes(let id, let decoded?, nil) = try WireCodec.decoder().decode(MacMessage.self, from: data) else {
            Issue.record("wrong case"); return
        }
        #expect(id == request)
        #expect(decoded.sameContent(as: snapshot))

        let diff = FileDiff(path: "a.swift", hunks: [DiffHunk(header: "@@ -1 +1,2 @@", oldStart: 1, oldCount: 1,
                                                             newStart: 1, newCount: 2, lines: [
            DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "x"),
            DiffLine(kind: .add, oldNumber: nil, newNumber: 2, text: "y"),
        ])])
        let diffData = try WireCodec.encoder().encode(MacMessage.fileDiff(requestId: request, diff: diff, error: nil))
        guard case .fileDiff(_, let decodedDiff?, nil) = try WireCodec.decoder().decode(MacMessage.self, from: diffData) else {
            Issue.record("wrong case"); return
        }
        #expect(decodedDiff == diff)

        let ask = PhoneMessage.requestDiff(requestId: request, paneId: UUID(), file: file)
        guard case .requestDiff(_, _, let askedFile) = try WireCodec.decoder().decode(
            PhoneMessage.self, from: try WireCodec.encoder().encode(ask)) else {
            Issue.record("wrong case"); return
        }
        #expect(askedFile == file)
    }

    @Test func historyRoundTrips() throws {
        let request = UUID()
        let info = PastSessionInfo(id: "abc", title: nil, firstPrompt: "fix the login bug", branch: "main",
                                   lastActivity: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try WireCodec.encoder().encode(MacMessage.history(requestId: request, sessions: [info], error: nil))
        guard case .history(request, let sessions?, nil) = try WireCodec.decoder().decode(MacMessage.self, from: data) else {
            Issue.record("wrong case"); return
        }
        #expect(sessions == [info])
        #expect(info.displayTitle == "fix the login bug")
        #expect(info.matches("login fix"))
        #expect(!info.matches("logout"))

        let ask = PhoneMessage.resumeSession(requestId: request, projectId: UUID(), sessionId: "abc")
        guard case .resumeSession(_, _, let id) = try WireCodec.decoder().decode(
            PhoneMessage.self, from: try WireCodec.encoder().encode(ask)) else {
            Issue.record("wrong case"); return
        }
        #expect(id == "abc")
    }

    @Test func startSessionCarriesTheAgent() throws {
        let codex = PhoneMessage.startSession(requestId: UUID(), projectId: UUID(), branch: nil, prompt: "",
                                              permissionMode: nil, agent: .codex)
        guard case .startSession(_, _, _, _, _, let agent) = try WireCodec.decoder().decode(
            PhoneMessage.self, from: try WireCodec.encoder().encode(codex)) else {
            Issue.record("wrong case"); return
        }
        #expect(agent == .codex)

        // A sender from before protocol 22 leaves the key out: that's Claude.
        let old = try WireCodec.encoder().encode(
            PhoneMessage.startSession(requestId: UUID(), projectId: UUID(), branch: "fix", prompt: "go",
                                      permissionMode: nil, agent: nil))
        #expect(!String(decoding: old, as: UTF8.self).contains("agent"))
        guard case .startSession(_, _, _, _, _, nil) = try WireCodec.decoder().decode(PhoneMessage.self, from: old) else {
            Issue.record("agent should decode as nil"); return
        }
    }

    @Test func filesAndDevServersRoundTrip() throws {
        let request = UUID()
        let file = RemoteFile(path: "a/b.swift", kind: .text, text: "let x = 1\n", truncated: false)
        let data = try WireCodec.encoder().encode(MacMessage.fileContent(requestId: request, file: file, error: nil))
        guard case .fileContent(request, let decoded?, nil) = try WireCodec.decoder().decode(MacMessage.self, from: data) else {
            Issue.record("wrong case"); return
        }
        #expect(decoded == file)

        let servers = [DevServerInfo(port: 5173, command: "node")]
        let serverData = try WireCodec.encoder().encode(MacMessage.devServers(requestId: request, servers: servers, error: nil))
        guard case .devServers(_, let decodedServers?, nil) = try WireCodec.decoder().decode(MacMessage.self, from: serverData) else {
            Issue.record("wrong case"); return
        }
        #expect(decodedServers == servers)

        let ask = PhoneMessage.requestFile(requestId: request, paneId: UUID(), path: "a/b.swift")
        guard case .requestFile(_, _, let path) = try WireCodec.decoder().decode(
            PhoneMessage.self, from: try WireCodec.encoder().encode(ask)) else {
            Issue.record("wrong case"); return
        }
        #expect(path == "a/b.swift")
    }

    @Test func imagesTravelAsBase64() throws {
        let image = Data([0xFF, 0xD8, 0xFF, 0x00, 0x01])
        let data = try WireCodec.encoder().encode(PhoneMessage.sendImage(requestId: UUID(), paneId: UUID(), image: image, text: "this"))
        guard case .sendImage(_, _, let decoded, let text) = try WireCodec.decoder().decode(PhoneMessage.self, from: data) else {
            Issue.record("wrong case"); return
        }
        #expect(decoded == image)
        #expect(text == "this")
    }

    @Test func hookPayloadDecodesSnakeCase() throws {
        let json = """
        {"session_id":"abc","cwd":"/x","transcript_path":"/x/t.jsonl",
         "hook_event_name":"Notification","notification_type":"permission_prompt","extra":1}
        """
        let p = try JSONDecoder().decode(TetherCore.HookPayload.self, from: Data(json.utf8))
        #expect(p.hookEventName == .notification)
        #expect(p.notificationType == "permission_prompt")
    }
}

@Suite struct ThemeAndInterruptTests {
    @Test func snapshotCarriesTheTheme() throws {
        let snapshot = Snapshot(macName: "m", projects: [], sessions: [], permissions: [],
                                theme: MacTheme(background: "#282c34", foreground: "#ffffff"))
        let data = try WireCodec.encoder().encode(MacMessage.snapshot(snapshot))
        guard case .snapshot(let decoded) = try WireCodec.decoder().decode(MacMessage.self, from: data) else {
            Issue.record("wrong case"); return
        }
        #expect(decoded.theme?.background == "#282c34")
    }

    @Test func interruptRoundTrips() throws {
        let pane = UUID()
        let data = try WireCodec.encoder().encode(PhoneMessage.interrupt(paneId: pane))
        guard case .interrupt(let id) = try WireCodec.decoder().decode(PhoneMessage.self, from: data) else {
            Issue.record("wrong case"); return
        }
        #expect(id == pane)
    }

    @Test func projectSectionsTravel() throws {
        let id = UUID()
        let summary = ProjectSummary(id: id, name: "Tether", branch: "main", pinned: true, active: true)
        let back = try WireCodec.decoder().decode(ProjectSummary.self, from: try WireCodec.encoder().encode(summary))
        #expect(back == summary)
        let data = try WireCodec.encoder().encode(PhoneMessage.setProjectActive(id: id, active: false))
        guard case .setProjectActive(let got, let active) = try WireCodec.decoder().decode(PhoneMessage.self, from: data) else {
            Issue.record("wrong case"); return
        }
        #expect(got == id && !active)
    }
}
