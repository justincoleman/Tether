import Foundation
import Testing
@testable import TetherCore

@Suite struct PullRequestTests {
    /// The shape of `gh pr view <branch> --json number,title,url,state,isDraft,statusCheckRollup`
    /// (gh 2.x): Actions jobs come as CheckRun, commit statuses as StatusContext.
    static let fixture = #"""
    {"isDraft":false,"number":9,"state":"OPEN","statusCheckRollup":[
      {"__typename":"CheckRun","completedAt":"2026-10-28T23:56:41Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/justincoleman/Tether/actions/runs/1/job/1","name":"swift test (Linux)","startedAt":"2026-10-28T23:55:14Z","status":"COMPLETED","workflowName":"CI"},
      {"__typename":"CheckRun","completedAt":"2026-10-28T23:56:49Z","conclusion":"FAILURE","detailsUrl":"https://github.com/justincoleman/Tether/actions/runs/1/job/2","name":"Build Mac + iPhone apps","startedAt":"2026-10-28T23:55:14Z","status":"COMPLETED","workflowName":"CI"},
      {"__typename":"CheckRun","completedAt":"0001-01-01T00:00:00Z","conclusion":"","detailsUrl":"https://github.com/justincoleman/Tether/actions/runs/1/job/3","name":"lint","startedAt":"2026-10-28T23:55:14Z","status":"IN_PROGRESS","workflowName":"CI"},
      {"__typename":"CheckRun","completedAt":"2026-10-28T23:56:49Z","conclusion":"SKIPPED","detailsUrl":"","name":"deploy","startedAt":"2026-10-28T23:55:14Z","status":"COMPLETED","workflowName":"CI"},
      {"__typename":"StatusContext","context":"vercel","startedAt":"2026-10-28T23:55:14Z","state":"PENDING","targetUrl":"https://vercel.com/x"}
    ],"title":"Overview: every Claude tab across projects as a grid","url":"https://github.com/justincoleman/Tether/pull/9"}
    """#

    @Test func parsesChecksFromBothKinds() throws {
        let pr = try PullRequestParser.parse(Data(Self.fixture.utf8))
        #expect(pr.number == 9)
        #expect(pr.state == .open)
        #expect(pr.url == "https://github.com/justincoleman/Tether/pull/9")
        #expect(pr.passed == 2)
        #expect(pr.failed == 1)
        #expect(pr.pending == 2)
        #expect(pr.failedNames == ["Build Mac + iPhone apps"])
        #expect(pr.checks == .failing)
        #expect(pr.checksSummary == "2 passed, 1 failed (Build Mac + iPhone apps), 2 running")
    }

    @Test func overallChecks() throws {
        func status(_ rollup: String) throws -> PullRequestStatus {
            let json = #"{"number":1,"title":"t","url":"u","state":"MERGED","isDraft":true,"statusCheckRollup":"# + rollup + "}"
            return try PullRequestParser.parse(Data(json.utf8))
        }
        #expect(try status("[]").checks == .none)
        #expect(try status("[]").state == .merged)
        #expect(try status("[]").isDraft)
        #expect(try status(#"[{"status":"QUEUED","conclusion":"","name":"a"}]"#).checks == .pending)
        #expect(try status(#"[{"status":"COMPLETED","conclusion":"SUCCESS","name":"a"},{"context":"b","state":"SUCCESS"}]"#).checks == .passing)
        #expect(try status(#"[{"context":"b","state":"ERROR"}]"#).checks == .failing)
    }

    @Test func missingRollupIsNoChecks() throws {
        let json = #"{"number":2,"title":"t","url":"u","state":"CLOSED"}"#
        let pr = try PullRequestParser.parse(Data(json.utf8))
        #expect(pr.state == .closed)
        #expect(pr.checks == .none)
        #expect(pr.checksSummary == "No checks")
    }

    @Test func recognisesNoPullRequest() {
        #expect(PullRequestParser.isNoPullRequest(#"no pull requests found for branch "feature""#))
        #expect(!PullRequestParser.isNoPullRequest("HTTP 401: Bad credentials"))
    }
}

@Suite struct PullRequestPolicyTests {
    func pr(_ state: PullRequestStatus.State, pending: Int = 0) -> PullRequestStatus {
        PullRequestStatus(number: 1, title: "t", url: "u", state: state, isDraft: false,
                          passed: 1, failed: 0, pending: pending, failedNames: [])
    }

    @Test func intervals() {
        #expect(PullRequestPolicy.interval(for: nil, appActive: true, lowPower: false) == 90)
        #expect(PullRequestPolicy.interval(for: pr(.open, pending: 1), appActive: true, lowPower: false) == 20)
        #expect(PullRequestPolicy.interval(for: pr(.open), appActive: true, lowPower: false) == 90)
        #expect(PullRequestPolicy.interval(for: pr(.merged, pending: 1), appActive: true, lowPower: false) == 600)
        #expect(PullRequestPolicy.interval(for: pr(.open, pending: 1), appActive: false, lowPower: false) == 300)
        #expect(PullRequestPolicy.interval(for: pr(.open), appActive: true, lowPower: true) == 270)
    }
}
