import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

final class TestClock: @unchecked Sendable {
    var t = Date(timeIntervalSince1970: 1_000_000)
}

@Suite struct CompanionAuthTests {
    func tempFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("companion-\(UUID()).json")
    }

    @Test func pairsOnceThenAuthenticates() async {
        let auth = CompanionAuth(fileURL: nil)
        let (code, _) = await auth.issueCode()
        #expect(code.count == 8)
        let first = await auth.pair(code: code.lowercased(), deviceName: "Justin's iPhone")
        #expect(first?.device.name == "Justin's iPhone")
        #expect(first?.token.count == 64)
        // Single use.
        #expect(await auth.pair(code: code, deviceName: "x") == nil)
        let device = await auth.authenticate(token: first!.token)
        #expect(device?.id == first?.device.id)
        #expect(await auth.authenticate(token: "nope") == nil)
    }

    @Test func codeExpires() async {
        let clock = TestClock()
        let auth = CompanionAuth(fileURL: nil, now: { clock.t })
        let (code, _) = await auth.issueCode()
        clock.t += CompanionAuth.codeLifetime + 1
        #expect(await auth.pair(code: code, deviceName: "x") == nil)
    }

    @Test func wrongGuessesBurnTheCode() async {
        let auth = CompanionAuth(fileURL: nil)
        let (code, _) = await auth.issueCode()
        for _ in 0..<CompanionAuth.maxAttempts {
            #expect(await auth.pair(code: "WRONGWRO", deviceName: "x") == nil)
        }
        #expect(await auth.pair(code: code, deviceName: "x") == nil)
    }

    @Test func pushRegistrationPersistsAndOldFilesStillLoad() async throws {
        let url = tempFile()
        // A companion.json written before push existed.
        let old = #"{"macId":"11111111-2222-3333-4444-555555555555","devices":[{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","name":"Phone","token":"t","pairedAt":"2026-10-01T00:00:00Z"}]}"#
        try Data(old.utf8).write(to: url)
        let auth = CompanionAuth(fileURL: url)
        let device = try #require(await auth.authenticate(token: "t"))
        #expect(device.push == nil)
        let reg = PushRegistration(deviceToken: "abcd", pushToStartToken: "ef01", bundleId: "com.x", sandbox: true)
        await auth.setPush(reg, for: device.id)
        await auth.setActivityToken("tok", pane: "p1", for: device.id)
        let reloaded = CompanionAuth(fileURL: url)
        #expect(await reloaded.devices.first?.push == reg)
        #expect(await reloaded.devices.first?.activityTokens == ["p1": "tok"])
        await reloaded.dropDeviceToken("abcd")
        #expect(await reloaded.devices.first?.push == nil)
        await reloaded.setActivityToken(nil, pane: "p1", for: device.id)
        #expect(await reloaded.devices.first?.activityTokens == nil)
    }

    @Test func persistsDevicesAndRevokes() async {
        let url = tempFile()
        let auth = CompanionAuth(fileURL: url)
        let macId = await auth.macId
        let (code, _) = await auth.issueCode()
        let paired = await auth.pair(code: code, deviceName: "Phone")!

        let reloaded = CompanionAuth(fileURL: url)
        #expect(await reloaded.macId == macId)
        #expect(await reloaded.authenticate(token: paired.token) != nil)
        await reloaded.revoke(paired.device.id)
        #expect(await reloaded.authenticate(token: paired.token) == nil)
        #expect(await CompanionAuth(fileURL: url).devices.isEmpty)
    }
}

@Suite struct TailnetTests {
    @Test func recognisesTailscaleRanges() {
        #expect(Tailnet.isTailnet("100.64.0.1"))
        #expect(Tailnet.isTailnet("100.101.102.103"))
        #expect(Tailnet.isTailnet("100.127.255.255"))
        #expect(!Tailnet.isTailnet("100.128.0.1"))
        #expect(!Tailnet.isTailnet("100.63.0.1"))
        #expect(!Tailnet.isTailnet("192.168.1.10"))
        #expect(Tailnet.isTailnet("fd7a:115c:a1e0::1"))
        #expect(Tailnet.isTailnet("fd7a:115c:a1e0:ab12::1%utun4"))
        #expect(!Tailnet.isTailnet("fe80::1"))
    }

    @Test func allowsOnlyTailnetAndLoopbackPeers() {
        #expect(Tailnet.isAllowedPeer("127.0.0.1"))
        #expect(Tailnet.isAllowedPeer("::1"))
        #expect(Tailnet.isAllowedPeer("::ffff:100.70.1.2"))
        #expect(!Tailnet.isAllowedPeer("::ffff:192.168.1.5"))
        #expect(!Tailnet.isAllowedPeer("10.0.0.4"))
    }

    @Test func prefersIPv4() {
        #expect(Tailnet.preferredAddress(from: ["192.168.1.2", "fd7a:115c:a1e0::5", "100.80.1.1"]) == "100.80.1.1")
        #expect(Tailnet.preferredAddress(from: ["fd7a:115c:a1e0::5"]) == "fd7a:115c:a1e0::5")
        #expect(Tailnet.preferredAddress(from: ["10.0.0.1"]) == nil)
    }
}

@Suite struct PairingLinkTests {
    @Test func roundTrips() {
        let link = PairingLink(host: "100.80.1.1", port: 7891, code: "ABCD2345", macName: "Mac mini")
        #expect(link.url.absoluteString.hasPrefix("tether://pair?v=1&host=100.80.1.1&port=7891"))
        #expect(PairingLink(url: link.url) == link)
    }

    @Test func rejectsBadLinks() {
        #expect(PairingLink(url: URL(string: "https://pair?v=1&host=a&port=1&code=x")!) == nil)
        #expect(PairingLink(url: URL(string: "tether://pair?v=2&host=a&port=1&code=x")!) == nil)
        #expect(PairingLink(url: URL(string: "tether://pair?v=1&host=a&port=99999&code=x")!) == nil)
        #expect(PairingLink(url: URL(string: "tether://pair?v=1&host=a&port=1")!) == nil)
    }
}
