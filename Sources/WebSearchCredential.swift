import Foundation
import Security

/// Separate from GitHub and gateway credentials; never exposed to the model.
enum WebSearchCredential {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.olivermikkola.keelmobile.web-search",
         kSecAttrAccount as String: account]
    }
    static func load(account: String = "brave") throws -> String {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw WebSearch.Problem.key }
        return key
    }
    static func contains() -> Bool {
        var request = query("brave")
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }
    static func save(_ key: String, account: String = "brave") throws {
        _ = try WebSearch.request(query: "validate", count: 1, key: key)
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let lookup = query(account)
        let status = SecItemUpdate(lookup as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound,
              SecItemAdd(lookup.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
            throw WebSearch.Problem.key
        }
    }
    static func remove(account: String = "brave") throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WebSearch.Problem.key }
    }
}
