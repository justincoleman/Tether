import Foundation
import Security

/// A Mac this phone has paired with. Stored in the Keychain because of the token.
struct PairedMac: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var token: String
}

/// The paired-Mac list as one Keychain item, readable after first unlock so
/// background work in phase 6 can use it.
enum MacKeychain {
    private static let service = "com.justincoleman.tether.macs"
    private static let account = "paired"

    static func load() -> [PairedMac] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let macs = try? JSONDecoder().decode([PairedMac].self, from: data)
        else { return [] }
        return macs
    }

    static func save(_ macs: [PairedMac]) {
        guard let data = try? JSONEncoder().encode(macs) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }
}
