import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Bounded Model Context Protocol (MCP) HTTP JSON-RPC 2.0 connector support.
///
/// A connector lets the user add an external service (such as Notion, Slack, or
/// an issue tracker) in Connections and switch it on only in the chats that
/// need it. Every tool schema takes context a small on-device model does not
/// have, so connector tools are never loaded into chats where the connector is
/// off, and each connector is capped at `maxToolsPerConnector` tools.
public enum MCPConnector {
    public static let maxConnectors = 8
    public static let maxToolsPerConnector = 5
    public static let maxPropertiesPerTool = 6
    public static let maxNameLength = 40
    public static let maxDescriptionLength = 240
    public static let maxArgumentBytes = 8 * 1024
    public static let responseLimit = 256 * 1024
    public static let textLimit = 4_000
    public static let timeout: TimeInterval = 15

    public struct Parameter: Codable, Equatable, Sendable {
        public let name: String
        public let type: String
        public let description: String
        public let required: Bool

        public init(name: String, type: String, description: String = "", required: Bool = false) {
            self.name = name
            self.type = type
            self.description = description
            self.required = required
        }
    }

    public struct Tool: Codable, Equatable, Sendable {
        /// Remote tool name as advertised by the MCP server (e.g. `search_pages`).
        public let remoteName: String
        /// Safe, lowercase snake_case function name offered to the local model (e.g. `mcp_notion_search_pages`).
        public let callName: String
        public let description: String
        public let parameters: [Parameter]

        public init(remoteName: String, callName: String, description: String, parameters: [Parameter]) {
            self.remoteName = remoteName
            self.callName = callName
            self.description = description
            self.parameters = parameters
        }

        /// JSON schema line formatted for `AgentPrompt.toolBlock` and `ToolCallGrammar`.
        public var schemaLine: String {
            var properties: [String: [String: Any]] = [:]
            var required: [String] = []
            for parameter in parameters {
                var prop: [String: Any] = ["type": parameter.type == "integer" ? "integer" : "string"]
                if !parameter.description.isEmpty {
                    prop["description"] = parameter.description
                }
                properties[parameter.name] = prop
                if parameter.required {
                    required.append(parameter.name)
                }
            }
            let parametersObject: [String: Any] = [
                "type": "object",
                "properties": properties,
                "required": required
            ]
            let functionObject: [String: Any] = [
                "name": callName,
                "description": description,
                "parameters": parametersObject
            ]
            let root: [String: Any] = [
                "type": "function",
                "function": functionObject
            ]
            let data = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    public struct Server: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public var name: String
        public var endpoint: String
        public var tools: [Tool]

        public init(id: String, name: String, endpoint: String, tools: [Tool] = []) {
            self.id = id
            self.name = name
            self.endpoint = endpoint
            self.tools = tools
        }
    }

    public enum Problem: LocalizedError, Equatable {
        case invalidName
        case invalidEndpoint
        case credentialsInURL
        case limitReached
        case invalidToken
        case unauthorized
        case unavailable(Int)
        case invalidResponse
        case remoteError(String)
        case unknownTool(String)
        case argumentTooLarge

        public var errorDescription: String? {
            switch self {
            case .invalidName:
                return "Give the connector a short name (1 to \(MCPConnector.maxNameLength) characters)."
            case .invalidEndpoint:
                return "Enter a valid https:// MCP endpoint (or http://127.0.0.1 for local testing)."
            case .credentialsInURL:
                return "Do not put a username, password or token in the endpoint URL. Save the token in the token field."
            case .limitReached:
                return "You can save up to \(MCPConnector.maxConnectors) MCP connectors."
            case .invalidToken:
                return "The connector token must be a single ASCII line up to 256 characters."
            case .unauthorized:
                return "The MCP server rejected the token. Check it in Connections."
            case .unavailable:
                return "The MCP server is unavailable right now."
            case .invalidResponse:
                return "The MCP server returned a reply Keel could not read."
            case .remoteError(let message):
                return "MCP error: \(message)"
            case .unknownTool(let name):
                return "Invalid tool call: '\(name)' is not enabled in this chat."
            case .argumentTooLarge:
                return "Invalid tool call: arguments exceed the \(MCPConnector.maxArgumentBytes)-byte limit."
            }
        }
    }

    /// Normalizes a human connector name into a stable lowercase identifier (`notion`, `linear_issues`).
    public static func slug(for name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxNameLength,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Problem.invalidName
        }
        let parts = trimmed.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let joined = String(parts.joined(separator: "_").prefix(20))
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !joined.isEmpty, joined.first?.isLetter == true else {
            throw Problem.invalidName
        }
        return joined
    }

    /// Validates an MCP HTTP endpoint: requires `https` (or `http` on loopback `127.0.0.1`/`localhost`)
    /// and rejects embedded credentials or secret query tokens.
    public static func validateEndpoint(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else {
            throw Problem.invalidEndpoint
        }
        guard components.user == nil, components.password == nil else {
            throw Problem.credentialsInURL
        }
        if let items = components.queryItems {
            let forbidden = ["token", "key", "api_key", "apikey", "secret", "auth", "access_token", "password"]
            if items.contains(where: { forbidden.contains($0.name.lowercased()) }) {
                throw Problem.credentialsInURL
            }
        }
        let isLoopback = host == "127.0.0.1" || host == "localhost"
        guard scheme == "https" || (scheme == "http" && isLoopback),
              let url = components.url else {
            throw Problem.invalidEndpoint
        }
        return url
    }

    public static func validateToken(_ token: String) throws -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 256,
              trimmed.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) else {
            throw Problem.invalidToken
        }
        return trimmed
    }

    /// Builds the safe function name exposed to the model (`mcp_<server>_<tool>`), matching `^[a-z_]+$`.
    public static func callName(serverID: String, remoteToolName: String) -> String? {
        func lettersOnly(_ text: String) -> String {
            let parts = text.lowercased()
                .components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz").inverted)
                .filter { !$0.isEmpty }
            return parts.joined(separator: "_")
        }
        let srv = String(lettersOnly(serverID).prefix(16))
        let tool = String(lettersOnly(remoteToolName).prefix(28))
        guard !srv.isEmpty, !tool.isEmpty else { return nil }
        return "mcp_\(srv)_\(tool)"
    }

    public static func isConnectorCall(_ name: String) -> Bool {
        name.hasPrefix("mcp_") && name.range(of: "^mcp_[a-z_]+$", options: .regularExpression) != nil
    }

    /// Builds a JSON-RPC 2.0 `tools/list` HTTP request.
    public static func listToolsRequest(endpoint: URL, token: String = "") throws -> URLRequest {
        let cleanToken = try validateToken(token)
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": [String: Any]()
        ]
        return try makeRequest(endpoint: endpoint, token: cleanToken, body: body)
    }

    /// Builds a JSON-RPC 2.0 `tools/call` HTTP request for a verified tool on `server`.
    public static func callToolRequest(server: Server, tool: Tool, arguments: [String: String], token: String = "") throws -> URLRequest {
        let endpoint = try validateEndpoint(server.endpoint)
        let cleanToken = try validateToken(token)
        var totalBytes = 0
        var typedArgs: [String: Any] = [:]
        let byName = Dictionary(uniqueKeysWithValues: tool.parameters.map { ($0.name, $0) })

        for key in arguments.keys.sorted() {
            guard let spec = byName[key], let rawValue = arguments[key] else {
                throw DirectorToolError.invalidCall("Unexpected parameter '\(key)' for \(tool.callName).")
            }
            totalBytes += key.utf8.count + rawValue.utf8.count
            guard totalBytes <= maxArgumentBytes else { throw Problem.argumentTooLarge }
            if spec.type == "integer" {
                guard let number = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw DirectorToolError.invalidCall("Parameter '\(key)' for \(tool.callName) must be an integer.")
                }
                typedArgs[key] = number
            } else {
                typedArgs[key] = rawValue
            }
        }
        for parameter in tool.parameters where parameter.required {
            guard typedArgs[parameter.name] != nil else {
                throw DirectorToolError.invalidCall("Missing required parameter '\(parameter.name)' for \(tool.callName).")
            }
        }

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": tool.remoteName,
                "arguments": typedArgs
            ]
        ]
        return try makeRequest(endpoint: endpoint, token: cleanToken, body: body)
    }

    private static func makeRequest(endpoint: URL, token: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Parses a JSON-RPC 2.0 `tools/list` response and keeps up to `maxToolsPerConnector` bounded tools.
    public static func parseTools(from data: Data, status: Int, serverID: String) throws -> [Tool] {
        try checkStatus(status)
        guard data.count <= responseLimit,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Problem.invalidResponse
        }
        if let err = root["error"] as? [String: Any], let msg = err["message"] as? String {
            throw Problem.remoteError(plain(msg, limit: 160))
        }
        guard let result = root["result"] as? [String: Any],
              let rawTools = result["tools"] as? [[String: Any]] else {
            throw Problem.invalidResponse
        }

        var tools: [Tool] = []
        var seenCallNames = Set<String>()
        for item in rawTools where tools.count < maxToolsPerConnector {
            guard let remoteName = item["name"] as? String,
                  !remoteName.isEmpty, remoteName.count <= 64,
                  let callName = callName(serverID: serverID, remoteToolName: remoteName),
                  seenCallNames.insert(callName).inserted else {
                continue
            }
            let rawDesc = (item["description"] as? String) ?? "Run \(remoteName) via MCP connector."
            let description = defuse(plain(rawDesc, limit: maxDescriptionLength))
            let schema = (item["inputSchema"] as? [String: Any]) ?? (item["parameters"] as? [String: Any]) ?? [:]
            let props = (schema["properties"] as? [String: [String: Any]]) ?? [:]
            let reqSet = Set((schema["required"] as? [String]) ?? [])

            var params: [Parameter] = []
            for key in props.keys.sorted() where params.count < maxPropertiesPerTool {
                guard key.range(of: "^[a-z_]+$", options: .regularExpression) != nil,
                      !["sql", "code", "old_text", "new_text"].contains(key) else {
                    continue
                }
                let rawType = (props[key]?["type"] as? String) ?? "string"
                guard ["string", "integer"].contains(rawType) else { continue }
                let propDesc = defuse(plain((props[key]?["description"] as? String) ?? "", limit: 120))
                params.append(Parameter(name: key, type: rawType, description: propDesc, required: reqSet.contains(key)))
            }
            params.sort { lhs, rhs in
                if lhs.required != rhs.required { return lhs.required && !rhs.required }
                return lhs.name < rhs.name
            }
            tools.append(Tool(remoteName: remoteName, callName: callName, description: description, parameters: params))
        }
        return tools
    }

    /// Parses a JSON-RPC 2.0 `tools/call` response into bounded, defused plain text for the model.
    public static func parseCallResult(from data: Data, status: Int, serverName: String, toolName: String) throws -> (text: String, isError: Bool) {
        try checkStatus(status)
        guard data.count <= responseLimit,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Problem.invalidResponse
        }
        if let err = root["error"] as? [String: Any], let msg = err["message"] as? String {
            throw Problem.remoteError(plain(msg, limit: 200))
        }
        guard let result = root["result"] as? [String: Any] else {
            throw Problem.invalidResponse
        }
        let isError = (result["isError"] as? Bool) ?? false
        var pieces: [String] = []
        if let content = result["content"] as? [[String: Any]] {
            for block in content {
                if let text = block["text"] as? String, !text.isEmpty {
                    pieces.append(text)
                }
            }
        } else if let text = result["text"] as? String, !text.isEmpty {
            pieces.append(text)
        }
        let body = defuse(pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        let clipped = clipUTF8(body.isEmpty ? "(empty result)" : body, maxBytes: textLimit)
        let header = "MCP result from \(serverName) · \(toolName) (untrusted external data):"
        return ("\(header)\n\(clipped)", isError)
    }

    /// Converts enabled connectors' tools into `ToolRouteCandidate` entries so `DynamicToolSelector`
    /// can route across workspace and connector tools under its active-schema budget.
    public static func routeCandidates(for servers: [Server]) -> [ToolRouteCandidate] {
        var candidates: [ToolRouteCandidate] = []
        for server in servers {
            let serverTokens = server.name.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 }
            for tool in server.tools {
                let nameTokens = tool.remoteName.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count >= 2 }
                let keywords = Array(Set([server.id] + serverTokens + nameTokens)).sorted()
                candidates.append(ToolRouteCandidate(
                    name: tool.callName,
                    summary: "\(server.name): \(tool.description)",
                    keywords: keywords,
                    followUpTools: [],
                    isCoreFallback: false
                ))
            }
        }
        return candidates
    }

    private static func checkStatus(_ status: Int) throws {
        switch status {
        case 200: break
        case 401, 403: throw Problem.unauthorized
        default: throw Problem.unavailable(status)
        }
    }

    private static func plain(_ text: String, limit: Int) -> String {
        let cleaned = text.filter { scalar in
            !scalar.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" })
        }
        let singleLine = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return singleLine.count > limit ? String(singleLine.prefix(limit - 1)) + "…" : singleLine
    }

    private static func defuse(_ text: String) -> String {
        text.replacingOccurrences(of: "<|", with: "< |")
            .replacingOccurrences(of: "<tool_call", with: "< tool_call")
            .replacingOccurrences(of: "</tool_call>", with: "</ tool_call>")
            .replacingOccurrences(of: "<function", with: "< function")
            .replacingOccurrences(of: "</function>", with: "</ function>")
            .replacingOccurrences(of: "<parameter", with: "< parameter")
            .replacingOccurrences(of: "</parameter>", with: "</ parameter>")
            .replacingOccurrences(of: "<tool_response>", with: "< tool_response>")
            .replacingOccurrences(of: "</tool_response>", with: "</ tool_response>")
    }

    private static func clipUTF8(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var result = ""
        result.reserveCapacity(maxBytes)
        var used = 0
        for char in text {
            let len = String(char).utf8.count
            if used + len > maxBytes { break }
            result.append(char)
            used += len
        }
        return result + "\n…[truncated]"
    }
}
