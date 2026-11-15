import Foundation
import Security

/// Keychain storage for MCP connector bearer tokens, keyed by connector slug.
/// Tokens stay in Keychain and are never saved in `SavedTasks` or sent to the model.
enum MCPConnectorCredential {
    private static func query(_ serverID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.olivermikkola.keelmobile.mcp-connector",
            kSecAttrAccount as String: serverID
        ]
    }

    static func load(serverID: String) throws -> String {
        var request = query(serverID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw MCPConnector.Problem.invalidToken
        }
        return token
    }

    static func contains(serverID: String) -> Bool {
        var request = query(serverID)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ token: String, serverID: String) throws {
        let clean = try MCPConnector.validateToken(token)
        if clean.isEmpty {
            try remove(serverID: serverID)
            return
        }
        let values: [String: Any] = [
            kSecValueData as String: Data(clean.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let lookup = query(serverID)
        let status = SecItemUpdate(lookup as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound,
              SecItemAdd(lookup.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
            throw MCPConnector.Problem.invalidToken
        }
    }

    static func remove(serverID: String) throws {
        let status = SecItemDelete(query(serverID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MCPConnector.Problem.invalidToken
        }
    }
}

/// Persists configured MCP connector servers (without tokens) beside `chat.json`.
enum MCPConnectorStore {
    static func defaultURL(beside transcript: URL) -> URL {
        transcript.deletingLastPathComponent().appendingPathComponent("mcp-connectors.json")
    }

    static func load(from url: URL) -> [MCPConnector.Server] {
        guard let data = try? Data(contentsOf: url),
              let servers = try? JSONDecoder().decode([MCPConnector.Server].self, from: data) else {
            return []
        }
        var valid: [MCPConnector.Server] = []
        var seen = Set<String>()
        for server in servers where valid.count < MCPConnector.maxConnectors {
            guard let slug = try? MCPConnector.slug(for: server.id), slug == server.id,
                  (try? MCPConnector.validateEndpoint(server.endpoint)) != nil,
                  seen.insert(server.id).inserted else {
                continue
            }
            let tools = Array(server.tools.prefix(MCPConnector.maxToolsPerConnector)).filter {
                MCPConnector.isConnectorCall($0.callName)
            }
            valid.append(MCPConnector.Server(id: server.id, name: server.name, endpoint: server.endpoint, tools: tools))
        }
        return valid
    }

    static func save(_ servers: [MCPConnector.Server], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(servers).write(to: url, options: [.atomic, .completeFileProtection])
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
    }
}
