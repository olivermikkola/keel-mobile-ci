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
    /// Tools one connector may offer the model in a chat.
    public static let maxToolsPerConnector = 5
    /// Tools kept from a server's list for the user to choose from.
    public static let maxDiscoveredTools = 30
    public static let protocolVersion = "2025-06-18"
    public static let maxTokenLength = 4_096
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
        /// The server's own spelling when it differs from `name` (`teamId` for `team_id`).
        public let remoteName: String?

        public init(name: String, type: String, description: String = "", required: Bool = false, remoteName: String? = nil) {
            self.name = name
            self.type = type
            self.description = description
            self.required = required
            self.remoteName = remoteName == name ? nil : remoteName
        }
    }

    public struct Tool: Codable, Equatable, Sendable {
        /// Remote tool name as advertised by the MCP server (e.g. `search_pages`).
        public let remoteName: String
        /// Safe, lowercase snake_case function name offered to the local model (e.g. `mcp_notion_search_pages`).
        public let callName: String
        public let description: String
        public let parameters: [Parameter]
        /// True only when the server marks the tool as one that changes nothing.
        public let readOnly: Bool?

        public init(remoteName: String, callName: String, description: String, parameters: [Parameter], readOnly: Bool? = nil) {
            self.remoteName = remoteName
            self.callName = callName
            self.description = description
            self.parameters = parameters
            self.readOnly = readOnly
        }

        /// JSON schema line formatted for `AgentPrompt.toolBlock` and `ToolCallGrammar`.
        public var schemaLine: String {
            var properties: [String: [String: Any]] = [:]
            var required: [String] = []
            for parameter in parameters {
                var prop: [String: Any] = ["type": ["integer", "number", "boolean"].contains(parameter.type) ? parameter.type : "string"]
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
        /// Tools offered to the model, at most `maxToolsPerConnector`.
        public var tools: [Tool]
        /// Every usable tool the server listed, for the user to choose from.
        public var available: [Tool]?
        /// Tools (by the server's names) the user chose to always allow.
        public var trusted: [String]?

        public init(id: String, name: String, endpoint: String, tools: [Tool] = [], available: [Tool]? = nil, trusted: [String]? = nil) {
            self.id = id
            self.name = name
            self.endpoint = endpoint
            self.tools = tools
            self.available = available
            self.trusted = trusted
        }

        /// A call needs the user's yes unless the server says the tool only
        /// reads, or the user chose to always allow it.
        public func needsApproval(_ tool: Tool) -> Bool {
            tool.readOnly != true && trusted?.contains(tool.remoteName) != true
        }
    }

    public enum Problem: LocalizedError, Equatable {
        case invalidName
        case invalidEndpoint
        case credentialsInURL
        case limitReached
        case invalidToken
        case unauthorized
        case sessionExpired
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
                return "Enter the connector's https:// address."
            case .credentialsInURL:
                return "Do not put a username, password or token in the address. Use the access token field instead."
            case .limitReached:
                return "You can add up to \(MCPConnector.maxConnectors) connectors."
            case .invalidToken:
                return "The access token must be a single line of plain characters."
            case .unauthorized:
                return "This connector needs you to sign in again. Open Connections and reconnect it."
            case .sessionExpired:
                return "The connector's session ended. Try again."
            case .unavailable:
                return "The connector is unavailable right now."
            case .invalidResponse:
                return "The connector returned a reply Keel could not read."
            case .remoteError(let message):
                return "Connector error: \(message)"
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
        guard trimmed.count <= maxTokenLength,
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

    /// What `initialize` agreed: the protocol version and, for servers that keep one, a session.
    public struct Session: Equatable, Sendable {
        public let protocolVersion: String
        public let sessionID: String?
        public init(protocolVersion: String = MCPConnector.protocolVersion, sessionID: String? = nil) {
            self.protocolVersion = protocolVersion
            self.sessionID = sessionID
        }
    }

    /// The first request to a server. Tools are listed and called only after it.
    public static func initializeRequest(endpoint: URL, token: String = "") throws -> URLRequest {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 0,
            "method": "initialize",
            "params": [
                "protocolVersion": protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": ["name": "Keel", "version": "1"]
            ] as [String: Any]
        ]
        return try makeRequest(endpoint: endpoint, token: try validateToken(token), body: body, session: nil)
    }

    /// Reads the `initialize` reply. `sessionHeader` is the reply's `Mcp-Session-Id`, if any.
    public static func parseInitialize(from data: Data, status: Int, contentType: String? = nil, sessionHeader: String? = nil) throws -> Session {
        try checkStatus(status)
        let root = try rpcObject(from: data, contentType: contentType, id: 0)
        if let err = root["error"] as? [String: Any], let msg = err["message"] as? String {
            throw Problem.remoteError(plain(msg, limit: 160))
        }
        guard let result = root["result"] as? [String: Any] else { throw Problem.invalidResponse }
        let offered = (result["protocolVersion"] as? String) ?? protocolVersion
        guard offered.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw Problem.invalidResponse }
        var session: String?
        if let header = sessionHeader?.trimmingCharacters(in: .whitespaces), !header.isEmpty {
            guard header.utf8.count <= 1_024,
                  header.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) else { throw Problem.invalidResponse }
            session = header
        }
        return Session(protocolVersion: offered, sessionID: session)
    }

    /// Tells the server the handshake is done. It answers 202 with no body.
    public static func initializedRequest(endpoint: URL, token: String = "", session: Session) throws -> URLRequest {
        let body: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        return try makeRequest(endpoint: endpoint, token: try validateToken(token), body: body, session: session)
    }

    /// Builds a JSON-RPC 2.0 `tools/list` HTTP request.
    public static func listToolsRequest(endpoint: URL, token: String = "", session: Session? = nil) throws -> URLRequest {
        let cleanToken = try validateToken(token)
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": [String: Any]()
        ]
        return try makeRequest(endpoint: endpoint, token: cleanToken, body: body, session: session)
    }

    /// The JSON-RPC reply to request `id`, from a plain JSON body or from an
    /// event stream (`text/event-stream`), which is how most servers answer.
    public static func rpcObject(from data: Data, contentType: String?, id: Int) throws -> [String: Any] {
        guard data.count <= responseLimit else { throw Problem.invalidResponse }
        let isStream = contentType?.lowercased().contains("text/event-stream") == true
        if !isStream, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return root }
        var replies: [[String: Any]] = []
        var lines: [String] = []
        func flush() {
            defer { lines = [] }
            guard !lines.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(lines.joined(separator: "\n").utf8)) as? [String: Any],
                  object["result"] != nil || object["error"] != nil else { return }
            replies.append(object)
        }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush(); continue }
            guard line.hasPrefix("data:") else { continue }
            var value = line.dropFirst(5)
            if value.first == " " { value = value.dropFirst() }
            lines.append(String(value))
        }
        flush()
        if let match = replies.first(where: { ($0["id"] as? Int) == id }) { return match }
        guard let last = replies.last else { throw Problem.invalidResponse }
        return last
    }

    /// Builds a JSON-RPC 2.0 `tools/call` HTTP request for a verified tool on `server`.
    public static func callToolRequest(server: Server, tool: Tool, arguments: [String: String], token: String = "", session: Session? = nil) throws -> URLRequest {
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
            let remote = spec.remoteName ?? key
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            switch spec.type {
            case "integer":
                guard let number = Int(trimmed) else {
                    throw DirectorToolError.invalidCall("Parameter '\(key)' for \(tool.callName) must be an integer.")
                }
                typedArgs[remote] = number
            case "number":
                guard let number = Double(trimmed), number.isFinite else {
                    throw DirectorToolError.invalidCall("Parameter '\(key)' for \(tool.callName) must be a number.")
                }
                typedArgs[remote] = number
            case "boolean":
                guard ["true", "false"].contains(trimmed.lowercased()) else {
                    throw DirectorToolError.invalidCall("Parameter '\(key)' for \(tool.callName) must be true or false.")
                }
                typedArgs[remote] = trimmed.lowercased() == "true"
            default:
                typedArgs[remote] = rawValue
            }
        }
        for parameter in tool.parameters where parameter.required {
            guard typedArgs[parameter.remoteName ?? parameter.name] != nil else {
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
        return try makeRequest(endpoint: endpoint, token: cleanToken, body: body, session: session)
    }

    private static func makeRequest(endpoint: URL, token: String, body: [String: Any], session: Session?) throws -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let session {
            request.setValue(session.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            if let id = session.sessionID { request.setValue(id, forHTTPHeaderField: "Mcp-Session-Id") }
        }
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// A parameter name the call format can carry (`^[a-z_]+$`) for a server's own
    /// spelling: `teamId` and `team-id` become `team_id`. Nil when nothing usable is left.
    public static func parameterName(for remote: String) -> String? {
        guard !remote.isEmpty, remote.count <= 48 else { return nil }
        var result = ""
        var previousLower = false
        for scalar in remote.unicodeScalars {
            guard scalar.isASCII else { return nil }
            let character = Character(scalar)
            if character.isUppercase {
                if previousLower { result.append("_") }
                result.append(contentsOf: character.lowercased())
                previousLower = false
            } else if character.isLowercase {
                result.append(character); previousLower = true
            } else if character == "_" || character == "-" || character == "." || character == " " {
                result.append("_"); previousLower = false
            } else {
                // Digits and other characters cannot appear in a call.
                return nil
            }
        }
        let name = result.split(separator: "_").joined(separator: "_")
        return name.isEmpty ? nil : name
    }

    /// Parses a `tools/list` reply into the tools a small model can call: up to
    /// `maxDiscoveredTools`, each with plain text, number or yes/no parameters.
    /// A tool that requires anything else (a list, a nested object) is left out
    /// rather than offered in a form that cannot work.
    public static func parseTools(from data: Data, status: Int, serverID: String, contentType: String? = nil) throws -> [Tool] {
        try checkStatus(status)
        let root = try rpcObject(from: data, contentType: contentType, id: 1)
        if let err = root["error"] as? [String: Any], let msg = err["message"] as? String {
            throw Problem.remoteError(plain(msg, limit: 160))
        }
        guard let result = root["result"] as? [String: Any],
              let rawTools = result["tools"] as? [[String: Any]] else {
            throw Problem.invalidResponse
        }

        var tools: [Tool] = []
        var seenCallNames = Set<String>()
        for item in rawTools where tools.count < maxDiscoveredTools {
            guard let remoteName = item["name"] as? String,
                  !remoteName.isEmpty, remoteName.count <= 64,
                  let callName = callName(serverID: serverID, remoteToolName: remoteName),
                  !seenCallNames.contains(callName) else {
                continue
            }
            let rawDesc = (item["description"] as? String) ?? "Run \(remoteName)."
            let description = defuse(plain(rawDesc, limit: maxDescriptionLength))
            let schema = (item["inputSchema"] as? [String: Any]) ?? (item["parameters"] as? [String: Any]) ?? [:]
            let props = (schema["properties"] as? [String: [String: Any]]) ?? [:]
            let reqSet = Set((schema["required"] as? [String]) ?? [])

            var params: [Parameter] = []
            var seenNames = Set<String>()
            var usable = true
            for key in props.keys.sorted(by: { (reqSet.contains($0) ? 0 : 1, $0) < (reqSet.contains($1) ? 0 : 1, $1) }) {
                let isRequired = reqSet.contains(key)
                let rawType = (props[key]?["type"] as? String) ?? "string"
                guard ["string", "integer", "number", "boolean"].contains(rawType),
                      let name = parameterName(for: key),
                      !["sql", "code", "old_text", "new_text"].contains(name),
                      params.count < maxPropertiesPerTool,
                      seenNames.insert(name).inserted else {
                    if isRequired { usable = false; break }
                    continue
                }
                let propDesc = defuse(plain((props[key]?["description"] as? String) ?? "", limit: 120))
                params.append(Parameter(name: name, type: rawType, description: propDesc, required: isRequired, remoteName: key))
            }
            guard usable else { continue }
            seenCallNames.insert(callName)
            let readOnly = (item["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool
            tools.append(Tool(remoteName: remoteName, callName: callName, description: description, parameters: params,
                              readOnly: readOnly == true ? true : nil))
        }
        return tools
    }

    /// The tools switched on when a connector is first added: `preferred` remote
    /// names first, then the server's own order, up to `maxToolsPerConnector`.
    public static func defaultSelection(from tools: [Tool], preferred: [String] = []) -> [Tool] {
        var chosen: [Tool] = []
        for name in preferred {
            if let tool = tools.first(where: { $0.remoteName == name }), !chosen.contains(tool) { chosen.append(tool) }
        }
        for tool in tools where !chosen.contains(tool) { chosen.append(tool) }
        return Array(chosen.prefix(maxToolsPerConnector))
    }

    /// Parses a JSON-RPC 2.0 `tools/call` response into bounded, defused plain text for the model.
    public static func parseCallResult(from data: Data, status: Int, serverName: String, toolName: String, contentType: String? = nil) throws -> (text: String, isError: Bool) {
        try checkStatus(status)
        let root = try rpcObject(from: data, contentType: contentType, id: 2)
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
        let header = "Result from \(serverName) · \(toolName) (untrusted external data):"
        return ("\(header)\n\(clipped)", isError)
    }

    /// What the user is shown before a call that may change something: the
    /// arguments as short `name: value` lines.
    public static func approvalSummary(arguments: [String: String]) -> String {
        arguments.keys.sorted().map { key in
            "\(key): \(plain(arguments[key] ?? "", limit: 200))"
        }.joined(separator: "\n")
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
        case 404: throw Problem.sessionExpired
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
