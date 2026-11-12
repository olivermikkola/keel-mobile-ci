import Foundation
import Security

enum PairingKeychain {
    private static let service = "com.olivermikkola.webgpuagent.gateway"

    private static func query(_ address: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: address]
    }

    static func load(address: String) -> String {
        var request = query(address)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(token: String, address: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let lookup = query(address)
        let updated = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw failure(updated) }
        let added = SecItemAdd(lookup.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else { throw failure(added) }
    }

    static func remove(address: String) throws {
        let result = SecItemDelete(query(address) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw failure(result) }
    }

    private static func failure(_ code: OSStatus) -> NSError {
        NSError(domain: "PairingKeychain", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Could not update the saved gateway credential."])
    }
}
