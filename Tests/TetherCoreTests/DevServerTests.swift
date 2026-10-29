import Foundation
import Testing
@testable import TetherCore

@Suite struct DevServerTests {
    /// Captured from `lsof -nP -iTCP -sTCP:LISTEN -Fpcn` (lsof 4.99, Linux):
    /// Claude Code's IDE bridge, another tool, and `python3 -m http.server`.
    static let linuxListeners = """
    p96
    cenvironment-man
    n127.0.0.1:33595
    p107
    cclaude
    n127.0.0.1:34457
    p261
    cpython3
    n*:8765

    """

    /// Same command on macOS: lsof adds an `f` field before each name, and
    /// a dual-stack server lists the port once per address family.
    static let macListeners = """
    p812
    cnode
    f23
    n*:5173
    f24
    n[::1]:5173
    p901
    cruby
    f12
    n127.0.0.1:3000
    p77
    crapportd
    f5
    n*:49152
    p640
    cnode
    f30
    n127.0.0.1:5173->127.0.0.1:61022

    """

    /// `lsof -a -d cwd -p 812,901,77 -Fpn` on macOS.
    static let macCwds = """
    p77
    fcwd
    n/
    p812
    fcwd
    n/Users/justin/code/site
    p901
    fcwd
    n/Users/justin/code/site/.claude/worktrees/api/server

    """

    @Test func parsesLinuxListeners() {
        let listeners = LsofParser.listeners(Self.linuxListeners)
        #expect(listeners.map(\.port) == [33595, 34457, 8765])
        #expect(listeners.map(\.command) == ["environment-man", "claude", "python3"])
        #expect(listeners.map(\.pid) == [96, 107, 261])
    }

    @Test func parsesMacListenersOncePerPort() {
        let listeners = LsofParser.listeners(Self.macListeners)
        #expect(listeners.map(\.port) == [5173, 3000, 49152])
        #expect(listeners.first?.command == "node")
    }

    @Test func ports() {
        #expect(LsofParser.port(of: "*:5173") == 5173)
        #expect(LsofParser.port(of: "[::1]:8080") == 8080)
        #expect(LsofParser.port(of: "127.0.0.1:3000") == 3000)
        #expect(LsofParser.port(of: "127.0.0.1:5173->127.0.0.1:61022") == nil)
        #expect(LsofParser.port(of: "localhost") == nil)
    }

    @Test func matchesServersToTheDeepestFolder() {
        let listeners = LsofParser.listeners(Self.macListeners)
        let cwds = LsofParser.workingDirectories(Self.macCwds)
        #expect(cwds[812] == "/Users/justin/code/site")
        let site = "/Users/justin/code/site"
        let worktree = "/Users/justin/code/site/.claude/worktrees/api/"
        let found = DevServerFinder.match(listeners: listeners, cwds: cwds,
                                          folders: [site, worktree, "/Users/justin/code/other"], excludingPid: 1)
        #expect(found[site]?.map(\.port) == [5173])
        // Trailing slash dropped; the server in a subfolder of the worktree counts.
        #expect(found["/Users/justin/code/site/.claude/worktrees/api"]?.map(\.port) == [3000])
        #expect(found["/Users/justin/code/other"] == nil)
        #expect(found.count == 2)
    }

    @Test func ignoresClaudeAndItself() {
        let listeners = LsofParser.listeners(Self.linuxListeners)
        let cwds: [Int32: String] = [96: "/home/user", 107: "/home/user/Tether", 261: "/home/user/Tether/web"]
        let found = DevServerFinder.match(listeners: listeners, cwds: cwds,
                                          folders: ["/home/user/Tether"], excludingPid: 96)
        #expect(found["/home/user/Tether"]?.map(\.command) == ["python3"])
    }

    @Test func folderPrefixNeedsAPathBoundary() {
        let listeners = [LsofParser.Listener(pid: 5, command: "node", port: 4000)]
        let found = DevServerFinder.match(listeners: listeners, cwds: [5: "/code/site-old"],
                                          folders: ["/code/site"], excludingPid: 1)
        #expect(found.isEmpty)
    }

    @Test func resolvesTmpSymlink() {
        let listeners = [LsofParser.Listener(pid: 5, command: "node", port: 4000)]
        let found = DevServerFinder.match(listeners: listeners, cwds: [5: "/private/tmp/demo"],
                                          folders: ["/tmp/demo"], excludingPid: 1)
        #expect(found["/private/tmp/demo"]?.first?.port == 4000)
    }

    @Test func parsesTypedAddresses() {
        #expect(PreviewTarget.parse("5173")?.absoluteString == "http://localhost:5173/")
        #expect(PreviewTarget.parse("8000/README.md")?.absoluteString == "http://localhost:8000/README.md")
        #expect(PreviewTarget.parse(" localhost:3000/admin ")?.absoluteString == "http://localhost:3000/admin")
        #expect(PreviewTarget.parse("https://example.com")?.absoluteString == "https://example.com")
        #expect(PreviewTarget.parse("") == nil)
        #expect(PreviewTarget.parse("not a url") == nil)
        #expect(PreviewTarget.parse("file:///etc/passwd") == nil)
    }

    @Test func choosesTarget() {
        let servers = [DevServer(port: 3000, pid: 1, command: "node"), DevServer(port: 5173, pid: 2, command: "node")]
        #expect(PreviewTarget.url(chosen: nil, servers: servers)?.port == 3000)
        #expect(PreviewTarget.url(chosen: URL(string: "http://localhost:8080"), servers: servers)?.port == 8080)
        #expect(PreviewTarget.url(chosen: nil, servers: []) == nil)
    }
}
