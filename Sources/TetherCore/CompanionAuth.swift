import Foundation
import TetherProtocol

/// A phone allowed to connect. The token is its long-lived bearer secret.
public struct PairedDevice: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var token: String
    public var pairedAt: Date
    public var lastSeen: Date?
    /// Where to push; nil until the phone allows notifications.
    public var push: PushRegistration?
    /// Live Activity update tokens by pane id string.
    public var activityTokens: [String: String]?
}

/// Pairing codes and the paired-device list for the companion server.
///
/// A pairing code is single-use, expires after `codeLifetime`, and is burned
/// after `maxAttempts` wrong guesses, so the short code cannot be brute-forced
/// during its window. Tokens are 256-bit random hex. The file is written 0600.
public actor CompanionAuth {
    public static let codeLifetime: TimeInterval = 120
    public static let maxAttempts = 5

    private struct State: Codable {
        var macId: UUID
        var devices: [PairedDevice]
    }

    private struct PendingCode {
        var code: String
        var expires: Date
        var failures: Int
    }

    private var state: State
    private var pending: PendingCode?
    private let fileURL: URL?
    private let now: @Sendable () -> Date

    public init(fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder.companion.decode(State.self, from: data) {
            state = loaded
        } else {
            state = State(macId: UUID(), devices: [])
        }
    }

    public var macId: UUID { state.macId }
    public var devices: [PairedDevice] { state.devices }

    /// Starts a pairing window, replacing any earlier code.
    public func issueCode() -> (code: String, expires: Date) {
        let code = Self.randomCode()
        let expires = now().addingTimeInterval(Self.codeLifetime)
        pending = PendingCode(code: code, expires: expires, failures: 0)
        return (code, expires)
    }

    public func cancelCode() { pending = nil }

    /// Redeems the current code for a new device. Nil when the code is wrong,
    /// expired or already used.
    public func pair(code: String, deviceName: String) -> (device: PairedDevice, token: String)? {
        guard var p = pending, now() < p.expires else { pending = nil; return nil }
        guard Self.constantTimeEqual(code.uppercased(), p.code) else {
            p.failures += 1
            pending = p.failures >= Self.maxAttempts ? nil : p
            return nil
        }
        pending = nil
        let token = Self.randomHex(bytes: 32)
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = PairedDevice(id: UUID(), name: name.isEmpty ? "iPhone" : name,
                                  token: token, pairedAt: now(), lastSeen: now())
        state.devices.append(device)
        save()
        return (device, token)
    }

    public func authenticate(token: String) -> PairedDevice? {
        guard let i = state.devices.firstIndex(where: { Self.constantTimeEqual($0.token, token) }) else {
            return nil
        }
        state.devices[i].lastSeen = now()
        save()
        return state.devices[i]
    }

    public func setPush(_ registration: PushRegistration?, for id: UUID) {
        guard let i = state.devices.firstIndex(where: { $0.id == id }) else { return }
        guard state.devices[i].push != registration else { return }
        state.devices[i].push = registration
        save()
    }

    public func setActivityToken(_ token: String?, pane: String, for id: UUID) {
        guard let i = state.devices.firstIndex(where: { $0.id == id }) else { return }
        var tokens = state.devices[i].activityTokens ?? [:]
        guard tokens[pane] != token else { return }
        tokens[pane] = token
        state.devices[i].activityTokens = tokens.isEmpty ? nil : tokens
        save()
    }

    /// APNs said the device token is no longer valid (app deleted, re-signed).
    public func dropDeviceToken(_ token: String) {
        var changed = false
        for i in state.devices.indices where state.devices[i].push?.deviceToken == token {
            state.devices[i].push = nil
            changed = true
        }
        if changed { save() }
    }

    public func revoke(_ id: UUID) {
        state.devices.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder.companion.encode(state)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("CompanionAuth: could not save \(fileURL.path): \(error)")
        }
    }

    // MARK: Helpers

    /// No 0/O/1/I, so a code read off the screen is unambiguous.
    static let codeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func randomCode(length: Int = 8) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in codeAlphabet.randomElement(using: &rng)! })
    }

    static func randomHex(bytes: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

private extension JSONEncoder {
    static var companion: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

private extension JSONDecoder {
    static var companion: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Tailscale addresses: IPv4 in 100.64.0.0/10 (CGNAT) and IPv6 in
/// fd7a:115c:a1e0::/48. The companion server accepts only these and loopback,
/// so traffic always rides Tailscale's WireGuard encryption.
public enum Tailnet {
    public static func isTailnet(_ address: String) -> Bool {
        let a = address.split(separator: "%").first.map(String.init) ?? address
        if a.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = a.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    public static func isLoopback(_ address: String) -> Bool {
        let a = address.split(separator: "%").first.map(String.init) ?? address
        return a == "::1" || a.hasPrefix("127.") || a == "::ffff:127.0.0.1"
    }

    /// Accepts IPv4-mapped IPv6 (`::ffff:100.64.0.1`) as its IPv4 form.
    public static func isAllowedPeer(_ address: String) -> Bool {
        let a = address.lowercased().hasPrefix("::ffff:") ? String(address.dropFirst(7)) : address
        return isTailnet(a) || isLoopback(a)
    }

    /// The address to put in the pairing QR: the first tailnet IPv4, else IPv6.
    public static func preferredAddress(from addresses: [String]) -> String? {
        addresses.first { isTailnet($0) && $0.contains(".") } ?? addresses.first { isTailnet($0) }
    }
}
