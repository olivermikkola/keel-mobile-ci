import Foundation
import Security

enum GitHubCredential {
    private static func query(_ account: String) -> [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.olivermikkola.keelmobile.github",
        kSecAttrAccount as String: account
    ] }

    static func oauthSession() throws -> GitHubOAuthSession? {
        let value = try load(account: "github-oauth")
        guard !value.isEmpty else { return nil }
        guard let data = value.data(using: .utf8) else { throw RepositoryError.credential }
        do { return try JSONDecoder().decode(GitHubOAuthSession.self, from: data) }
        catch { throw RepositoryError.credential }
    }

    static func saveOAuthSession(_ session: GitHubOAuthSession) throws {
        let value = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        try save(value, account: "github-oauth")
    }

    static func load(account: String = "github.com") throws -> String {
        if account == "github.com", let session = try oauthSession() { return session.accessToken }
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw RepositoryError.credential
        }
        return token
    }

    static func contains(account: String = "github.com") -> Bool {
        if account == "github.com", (try? oauthSession()) != nil { return true }
        var request = query(account)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ token: String, account: String = "github.com") throws {
        // A manually chosen replacement token explicitly replaces OAuth.
        let values: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let lookup = query(account)
        let updated = SecItemUpdate(lookup as CFDictionary, values as CFDictionary)
        if updated == errSecSuccess {
            if account == "github.com" { try remove(account: "github-oauth") }
            return
        }
        guard updated == errSecItemNotFound,
              SecItemAdd(lookup.merging(values) { _, value in value } as CFDictionary, nil) == errSecSuccess else {
            throw RepositoryError.credential
        }
        if account == "github.com" { try remove(account: "github-oauth") }
    }

    static func remove(account: String = "github.com") throws {
        if account == "github.com" { try remove(account: "github-oauth") }
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RepositoryError.credential }
    }
}
