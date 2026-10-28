import CryptoKit
import Foundation
import Observation
import Security
import TetherCore
import TetherProtocol

/// APNs credentials: team id and key id in defaults, the `.p8` key in the
/// Keychain. Entered in Settings → iPhone.
@MainActor
@Observable
final class PushSettings {
    var teamId: String {
        didSet { UserDefaults.standard.set(teamId, forKey: "apnsTeamId") }
    }
    var keyId: String {
        didSet { UserDefaults.standard.set(keyId, forKey: "apnsKeyId") }
    }
    private(set) var hasKey: Bool

    private static let service = "com.justincoleman.tether.apns"

    init() {
        teamId = UserDefaults.standard.string(forKey: "apnsTeamId") ?? ""
        keyId = UserDefaults.standard.string(forKey: "apnsKeyId") ?? ""
        hasKey = Self.loadKey() != nil
    }

    var isComplete: Bool { hasKey && !teamId.isEmpty && !keyId.isEmpty }

    /// Validates and stores a `.p8` file's contents. Returns an error message.
    func importKey(pem: String) -> String? {
        guard (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil else {
            return "That file isn't an APNs .p8 key."
        }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: Self.service]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(pem.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        hasKey = status == errSecSuccess
        return hasKey ? nil : "Couldn't save the key to the Keychain (\(status))."
    }

    func credentials() -> PushSender.Credentials? {
        guard isComplete, let pem = Self.loadKey() else { return nil }
        return PushSender.Credentials(teamId: teamId.trimmingCharacters(in: .whitespaces),
                                      keyId: keyId.trimmingCharacters(in: .whitespaces), pem: pem)
    }

    private static func loadKey() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Sends pushes straight to APNs over HTTP/2 with a token-auth JWT. No
/// server: each Mac signs with the user's own key.
actor PushSender {
    struct Credentials: Sendable, Equatable {
        var teamId: String
        var keyId: String
        var pem: String
    }

    enum Result: Sendable, Equatable {
        case sent
        /// The token is dead (app removed or reinstalled); forget it.
        case unregistered
        case failed(String)
    }

    private var cached: (credentials: Credentials, token: String, issued: Date)?

    func send(_ request: APNsRequest, token: String, bundleId: String, sandbox: Bool,
              credentials: Credentials) async -> Result {
        let jwt: String
        do {
            jwt = try providerToken(credentials)
        } catch {
            return .failed("Couldn't sign with the APNs key: \(error.localizedDescription)")
        }
        guard let url = URL(string: "\(APNsRequest.host(sandbox: sandbox))/3/device/\(token)") else {
            return .failed("Bad device token.")
        }
        var http = URLRequest(url: url)
        http.httpMethod = "POST"
        http.httpBody = request.body
        http.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        for (k, v) in request.headers(bundleId: bundleId) { http.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await URLSession.shared.data(for: http)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return .sent }
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String ?? "HTTP \(status)"
            if status == 410 || reason == "BadDeviceToken" || reason == "Unregistered" { return .unregistered }
            if reason == "ExpiredProviderToken" || reason == "InvalidProviderToken" { cached = nil }
            return .failed(reason)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func providerToken(_ credentials: Credentials) throws -> String {
        if let cached, cached.credentials == credentials, Date().timeIntervalSince(cached.issued) < APNsJWT.lifetime {
            return cached.token
        }
        let key = try P256.Signing.PrivateKey(pemRepresentation: credentials.pem)
        let now = Date()
        let token = try APNsJWT.make(teamId: credentials.teamId, keyId: credentials.keyId, issuedAt: now) { input in
            try key.signature(for: input).rawRepresentation
        }
        cached = (credentials, token, now)
        return token
    }
}
