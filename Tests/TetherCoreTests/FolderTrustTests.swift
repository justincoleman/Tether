import Foundation
import Testing
import TetherProtocol
@testable import TetherCore

@Suite struct FolderTrustTests {
    private func config(_ projects: String) -> Data {
        Data(#"{"numStartups":3,"projects":{\#(projects)}}"#.utf8)
    }

    @Test func acceptedFolderIsTrusted() {
        let c = config(#""/Users/j/app":{"hasTrustDialogAccepted":true}"#)
        #expect(FolderTrust.isTrusted("/Users/j/app", config: c))
    }

    @Test func trustCoversSubfolders() {
        let c = config(#""/Users/j/app":{"hasTrustDialogAccepted":true}"#)
        #expect(FolderTrust.isTrusted("/Users/j/app/Worktrees/feature", config: c))
    }

    @Test func unknownOrDeclinedFolderIsNotTrusted() {
        let c = config(#""/Users/j/app":{"hasTrustDialogAccepted":false},"/Users/j/other":{"allowedTools":[]}"#)
        #expect(!FolderTrust.isTrusted("/Users/j/app", config: c))
        #expect(!FolderTrust.isTrusted("/Users/j/other", config: c))
        #expect(!FolderTrust.isTrusted("/Users/j/new", config: c))
    }

    @Test func siblingWithSharedPrefixIsNotCovered() {
        let c = config(#""/Users/j/app":{"hasTrustDialogAccepted":true}"#)
        #expect(!FolderTrust.isTrusted("/Users/j/app2", config: c))
    }

    @Test func unreadableConfigIsTreatedAsTrusted() {
        #expect(FolderTrust.isTrusted("/x", config: nil))
        #expect(FolderTrust.isTrusted("/x", config: Data("not json".utf8)))
        #expect(FolderTrust.isTrusted("/x", config: Data(#"{"numStartups":1}"#.utf8)))
    }

    @Test func trustCardSummaryAndHeading() {
        let s = PermissionSummary.describe(toolName: TrustFolder.toolName, input: .object(["path": .string("/p")]))
        #expect(s.title == "Trust this folder" && s.detail == "/p")
        let request = PermissionRequested(id: UUID(), paneId: nil, sessionId: "s", toolName: TrustFolder.toolName,
                                          title: s.title, detail: s.detail)
        #expect(request.isFolderTrust)
        #expect(request.heading == "Do you trust the files in this folder?")
        let bash = PermissionRequested(id: UUID(), paneId: nil, sessionId: "s", toolName: "Bash",
                                       title: "Run a command", detail: "ls")
        #expect(!bash.isFolderTrust && bash.heading == "Claude wants to run a command")
    }
}
