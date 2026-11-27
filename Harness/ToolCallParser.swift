import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// Which wire format the model used to emit tool calls in a turn.
public enum ToolCallFormat: String, Equatable, Sendable {
    /// `<tool_call><function=name><parameter=k>v</parameter></function></tool_call>` (or bare `<function=...>`)
    case qwenXML
    /// `<tool_call>{"name": "...", "arguments": {...}}</tool_call>` (or JSON array inside `<tool_call>`)
    case jsonTag
    /// `<function name="..."><param name="...">...</param></function>`
    case miniCPMXML
    /// `<|tool_call_start|>[func(k="v"), ...]<|tool_call_end|>`
    case lfmPython
}

/// Multi-format, multi-call parser for on-device agent turns.
///
/// Supports:
/// - Qwen XML (single or multiple `<tool_call>` / bare `<function=>` blocks)
/// - JSON tool calls inside `<tool_call>...</tool_call>` (single object or batch array)
/// - MiniCPM5 XML (`<function name="..."><param name="...">...</param></function>`, single or multiple)
/// - LFM2/3 native calls (`<|tool_call_start|>[fn(a="b"), ...]<|tool_call_end|>`)
///
/// Security invariants:
/// - Never parses tool calls hidden inside `<think>...</think>` reasoning blocks.
/// - Rejects unknown tool names, duplicate parameters, nested protocol tags inside code/SQL,
///   XML external entities (XXE), and oversized payloads.
/// - Caps calls per turn (`maxCallsPerTurn`) so one turn cannot flood the loop.
enum ToolCallParser {
    static let maxCallsPerTurn = 6
    static let maxPayloadBytes = 96 * 1024

    struct ParsedTurn: Equatable {
        let calls: [DirectorCall]
        let format: ToolCallFormat
        let narration: String
        let repaired: Bool
        let droppedTrailing: String
    }

    /// Parses zero, one, or several tool calls from model output.
    /// Returns `nil` when the reply is plain assistant text with no tool markup.
    static func parseAll(
        _ output: String,
        family: ModelFamily = .bonsai,
        maxCalls: Int = maxCallsPerTurn
    ) throws -> ParsedTurn? {
        let rawTrimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTrimmed.isEmpty else { return nil }

        // 1. Strip leaked reasoning prefix ending in `</think>` ONLY when no
        // tool markup appears before that `</think>`. This prevents an earlier
        // call or argument containing `</think>` from hiding or promoting markup.
        var working = rawTrimmed
        var repaired = false
        if let close = working.range(of: "</think>", options: .backwards) {
            let before = working[..<close.lowerBound]
            let after = working[close.upperBound...]
            if !containsAnyCallMarker(before), containsAnyCallMarker(after) {
                working = String(after).trimmingCharacters(in: .whitespacesAndNewlines)
                repaired = true
            }
        }

        // Plain answer with no tool markers at all.
        guard containsAnyCallMarker(working) else { return nil }
        guard working.utf8.count <= maxPayloadBytes else {
            throw DirectorToolError.invalidCall("Tool call output exceeds the 96 KB limit.")
        }

        // 2. Dispatch to the matching format parser in unambiguous priority order.
        if working.contains("<|tool_call_start|>") {
            return try parseLFMPython(working, maxCalls: maxCalls, repairedPrefix: repaired)
        }

        if working.contains("<tool_call") {
            // Check whether `<tool_call>` carries JSON (`{` or `[`) or Qwen XML (`<function=`).
            if looksLikeJSONToolCall(working) {
                return try parseJSONTagCalls(working, maxCalls: maxCalls, repairedPrefix: repaired)
            }
            return try parseQwenXMLCalls(working, maxCalls: maxCalls, repairedPrefix: repaired)
        }

        if working.contains("<function=") {
            return try parseQwenXMLCalls(working, maxCalls: maxCalls, repairedPrefix: repaired)
        }

        if working.contains("<function ") || working.contains("<function\t") || working.contains("<function\n")
            || (family == .miniCPM5 && (working.contains("<function") || working.contains("<param"))) {
            return try parseMiniCPMCalls(working, maxCalls: maxCalls, repairedPrefix: repaired)
        }

        // Stray closing marker like `</tool_call>` with no opening block.
        throw DirectorToolError.invalidCall("Malformed <tool_call> tags.")
    }

    private static func containsAnyCallMarker<S: StringProtocol>(_ text: S) -> Bool {
        text.contains("<tool_call")
            || text.contains("</tool_call>")
            || text.contains("<function=")
            || text.contains("<function ")
            || text.contains("<function\t")
            || text.contains("<function\n")
            || text.contains("<|tool_call_start|>")
    }

    private static func looksLikeJSONToolCall(_ text: String) -> Bool {
        guard let open = text.range(of: "<tool_call>") else { return false }
        let after = text[open.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return after.hasPrefix("{") || after.hasPrefix("[")
    }

    // MARK: - Qwen XML (single or multi-call)

    private static func parseQwenXMLCalls(_ input: String, maxCalls: Int, repairedPrefix: Bool) throws -> ParsedTurn {
        var repaired = repairedPrefix
        let text = stripOuterMarkdownFence(input, didStrip: &repaired)

        // Extract every `<tool_call>...</tool_call>` block, or bare `<function=...>...</function>` blocks.
        var blocks: [(range: Range<String.Index>, inner: String)] = []
        if text.contains("<tool_call>") {
            var cursor = text.startIndex
            while let open = text.range(of: "<tool_call>", range: cursor..<text.endIndex) {
                let searchFrom = open.upperBound
                if let close = text.range(of: "</tool_call>", range: searchFrom..<text.endIndex) {
                    // Reject a nested `<tool_call>` inside an unclosed block.
                    if text[searchFrom..<close.lowerBound].contains("<tool_call>") {
                        throw DirectorToolError.invalidCall("Nested or unclosed <tool_call> tag.")
                    }
                    blocks.append((open.lowerBound..<close.upperBound, String(text[searchFrom..<close.lowerBound])))
                    cursor = close.upperBound
                } else if let fnEnd = text.range(of: "</function>", range: searchFrom..<text.endIndex),
                          !text[searchFrom..<fnEnd.lowerBound].contains("<tool_call>") {
                    // Missing closing `</tool_call>` on the final block: recover cleanly.
                    blocks.append((open.lowerBound..<fnEnd.upperBound, String(text[searchFrom..<fnEnd.upperBound])))
                    repaired = true
                    cursor = fnEnd.upperBound
                    break
                } else {
                    throw DirectorToolError.invalidCall("Malformed <tool_call> tags.")
                }
            }
        } else {
            // Bare `<function=...>...</function>` blocks without `<tool_call>`.
            var cursor = text.startIndex
            while let open = text.range(of: "<function=", range: cursor..<text.endIndex) {
                guard let close = text.range(of: "</function>", range: open.upperBound..<text.endIndex) else {
                    throw DirectorToolError.invalidCall("Malformed <function> tag.")
                }
                blocks.append((open.lowerBound..<close.upperBound, String(text[open.lowerBound..<close.upperBound])))
                repaired = true
                cursor = close.upperBound
            }
        }

        guard !blocks.isEmpty else {
            throw DirectorToolError.invalidCall("Malformed <tool_call> tags.")
        }
        guard blocks.count <= maxCalls else {
            throw DirectorToolError.invalidCall("Too many tool calls in one turn (maximum \(maxCalls)).")
        }

        // Between consecutive blocks, only whitespace (or a markdown fence boundary) is allowed.
        for i in 1..<blocks.count {
            let between = text[blocks[i - 1].range.upperBound..<blocks[i].range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !between.isEmpty {
                throw DirectorToolError.invalidCall("Unexpected text between tool calls.")
            }
        }

        let leading = ToolCallText.stripFenceOpening(String(text[..<blocks[0].range.lowerBound]))
        let trailing = ToolCallText.stripFenceClosing(String(text[blocks.last!.range.upperBound...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty { repaired = true }

        var calls: [DirectorCall] = []
        for block in blocks {
            let trimmedInner = block.inner.trimmingCharacters(in: .whitespacesAndNewlines)
            // A `<tool_call>` block could contain either `<function=...>` or JSON `{...}` in mixed cases.
            if trimmedInner.hasPrefix("{") || trimmedInner.hasPrefix("[") {
                calls.append(contentsOf: try parseJSONCallPayload(trimmedInner))
            } else {
                let canonical = "<tool_call>\n" + trimmedInner + "\n</tool_call>"
                guard let call = try DirectorCall.parse(canonical) else {
                    throw DirectorToolError.invalidCall("Malformed <tool_call> tags.")
                }
                calls.append(call)
            }
        }
        guard calls.count <= maxCalls else {
            throw DirectorToolError.invalidCall("Too many tool calls in one turn (maximum \(maxCalls)).")
        }

        return ParsedTurn(calls: calls, format: .qwenXML, narration: leading, repaired: repaired, droppedTrailing: trailing)
    }

    // MARK: - JSON inside <tool_call>...</tool_call>

    private static func parseJSONTagCalls(_ input: String, maxCalls: Int, repairedPrefix: Bool) throws -> ParsedTurn {
        var repaired = repairedPrefix
        let text = stripOuterMarkdownFence(input, didStrip: &repaired)

        var blocks: [(range: Range<String.Index>, payload: String)] = []
        var cursor = text.startIndex
        while let open = text.range(of: "<tool_call>", range: cursor..<text.endIndex) {
            let searchFrom = open.upperBound
            if let close = text.range(of: "</tool_call>", range: searchFrom..<text.endIndex) {
                blocks.append((open.lowerBound..<close.upperBound, String(text[searchFrom..<close.lowerBound])))
                cursor = close.upperBound
            } else {
                // Allow missing closing `</tool_call>` if the remainder is valid JSON.
                let rest = String(text[searchFrom...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty, (try? JSONSerialization.jsonObject(with: Data(rest.utf8))) != nil {
                    blocks.append((open.lowerBound..<text.endIndex, rest))
                    repaired = true
                    break
                }
                throw DirectorToolError.invalidCall("Unclosed <tool_call> JSON block.")
            }
        }

        guard !blocks.isEmpty else {
            throw DirectorToolError.invalidCall("Malformed <tool_call> JSON block.")
        }
        for i in 1..<blocks.count {
            let between = text[blocks[i - 1].range.upperBound..<blocks[i].range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !between.isEmpty {
                throw DirectorToolError.invalidCall("Unexpected text between tool calls.")
            }
        }

        let leading = ToolCallText.stripFenceOpening(String(text[..<blocks[0].range.lowerBound]))
        let trailing = ToolCallText.stripFenceClosing(String(text[blocks.last!.range.upperBound...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty { repaired = true }

        var calls: [DirectorCall] = []
        for block in blocks {
            calls.append(contentsOf: try parseJSONCallPayload(block.payload))
        }
        guard !calls.isEmpty else {
            throw DirectorToolError.invalidCall("Empty tool call list.")
        }
        guard calls.count <= maxCalls else {
            throw DirectorToolError.invalidCall("Too many tool calls in one turn (maximum \(maxCalls)).")
        }

        return ParsedTurn(calls: calls, format: .jsonTag, narration: leading, repaired: repaired, droppedTrailing: trailing)
    }

    private static func parseJSONCallPayload(_ payload: String) throws -> [DirectorCall] {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            throw DirectorToolError.invalidCall("Malformed JSON inside <tool_call>.")
        }
        if let dict = json as? [String: Any] {
            return [try directorCall(fromJSON: dict)]
        }
        if let array = json as? [[String: Any]] {
            guard !array.isEmpty else { throw DirectorToolError.invalidCall("Empty tool call array.") }
            return try array.map(directorCall(fromJSON:))
        }
        throw DirectorToolError.invalidCall("Expected a JSON object or array inside <tool_call>.")
    }

    private static func directorCall(fromJSON object: [String: Any]) throws -> DirectorCall {
        let target = (object["function"] as? [String: Any]) ?? object
        guard let name = target["name"] as? String,
              name.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil else {
            throw DirectorToolError.invalidCall("Missing or invalid tool name in JSON tool call.")
        }
        guard ToolRegistry.isAllowedToolName(name) else {
            throw DirectorToolError.invalidCall("Unknown tool name: '\(name)'.")
        }

        let rawArgsObject = target["arguments"] ?? target["parameters"]
        let argsDict: [String: Any]
        if rawArgsObject == nil || rawArgsObject is NSNull {
            argsDict = [:]
        } else if let dict = rawArgsObject as? [String: Any] {
            argsDict = dict
        } else if let str = rawArgsObject as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                argsDict = [:]
            } else if let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] {
                argsDict = parsed
            } else {
                throw DirectorToolError.invalidCall("Invalid JSON string for arguments in \(name).")
            }
        } else {
            throw DirectorToolError.invalidCall("Arguments for \(name) must be a JSON object.")
        }

        var args: [String: String] = [:]
        var raw: [String: String] = [:]
        for (key, value) in argsDict {
            guard key.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil else {
                throw DirectorToolError.invalidCall("Invalid parameter name '\(key)' in \(name).")
            }
            if value is NSNull { continue }
            let stringValue = try stringifyJSONArgument(value, key: key, toolName: name)
            if ["sql", "code"].contains(key),
               ["<parameter=", "<function=", "<tool_call"].contains(where: { stringValue.contains($0) }) {
                throw DirectorToolError.invalidCall("Nested tool tag inside \(key) parameter.")
            }
            args[key] = stringValue
            if ["old_text", "new_text"].contains(key) { raw[key] = stringValue }
        }
        return DirectorCall(name: name, arguments: args, rawArguments: raw)
    }

    private static func stringifyJSONArgument(_ value: Any, key: String, toolName: String) throws -> String {
        if let str = value as? String {
            return str
        }
        #if canImport(CoreFoundation)
        // On Apple platforms JSONSerialization bridges booleans and numbers to NSNumber.
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            if floor(number.doubleValue) == number.doubleValue,
               number.doubleValue >= Double(Int64.min), number.doubleValue <= Double(Int64.max) {
                return String(number.int64Value)
            }
            return number.stringValue
        }
        #else
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let int = value as? Int {
            return String(int)
        }
        if let int64 = value as? Int64 {
            return String(int64)
        }
        if let double = value as? Double {
            if floor(double) == double, double >= Double(Int64.min), double <= Double(Int64.max) {
                return String(Int64(double))
            }
            return String(double)
        }
        if let number = value as? NSNumber {
            if String(cString: number.objCType) == "c" || String(cString: number.objCType) == "B" {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        #endif
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: data, as: UTF8.self)
        }
        throw DirectorToolError.invalidCall("Unsupported value type for parameter '\(key)' in \(toolName).")
    }

    // MARK: - MiniCPM5 XML (single or multi-call, XXE-safe)

    private static func parseMiniCPMCalls(_ input: String, maxCalls: Int, repairedPrefix: Bool) throws -> ParsedTurn {
        var repaired = repairedPrefix
        let text = stripOuterMarkdownFence(input, didStrip: &repaired)

        guard let firstStart = text.range(of: "<function"),
              let lastEnd = text.range(of: "</function>", options: .backwards),
              firstStart.lowerBound < lastEnd.upperBound else {
            throw DirectorToolError.invalidCall("Malformed native tool call.")
        }
        let leadingRaw = String(text[..<firstStart.lowerBound])
        guard !leadingRaw.contains("<") else {
            throw DirectorToolError.invalidCall("Malformed native tool call.")
        }
        let leading = ToolCallText.stripFenceOpening(leadingRaw)
        let trailing = ToolCallText.stripFenceClosing(String(text[lastEnd.upperBound...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty { repaired = true }

        let xmlBody = String(text[firstStart.lowerBound..<lastEnd.upperBound])
        let parser = XMLParser(data: Data(("<keel_native_calls>" + xmlBody + "</keel_native_calls>").utf8))
        let reader = MultiXMLReader()
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !reader.invalid, reader.depth == 0, !reader.calls.isEmpty else {
            throw DirectorToolError.invalidCall("Malformed native tool call.")
        }
        guard reader.calls.count <= maxCalls else {
            throw DirectorToolError.invalidCall("Too many tool calls in one turn (maximum \(maxCalls)).")
        }

        var parsed: [DirectorCall] = []
        for entry in reader.calls {
            let canonical = NativeToolCall.canonicalCall(name: entry.name, arguments: entry.arguments)
            guard let call = try DirectorCall.parse(canonical) else {
                throw DirectorToolError.invalidCall("Malformed native tool call.")
            }
            parsed.append(call)
        }
        return ParsedTurn(calls: parsed, format: .miniCPMXML, narration: leading, repaired: repaired, droppedTrailing: trailing)
    }

    private final class MultiXMLReader: NSObject, XMLParserDelegate {
        var depth = 0
        var invalid = false
        var calls: [(name: String, arguments: [String: String])] = []
        private var currentName: String?
        private var currentArgs: [String: String] = [:]
        private var currentParam: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            if depth == 1 {
                guard elementName == "keel_native_calls", attributes.isEmpty else {
                    invalid = true; parser.abortParsing(); return
                }
                return
            }
            guard attributes.count == 1, let value = attributes["name"],
                  value.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil else {
                invalid = true; parser.abortParsing(); return
            }
            if depth == 2 && elementName == "function" && currentName == nil {
                currentName = value
                currentArgs = [:]
            } else if depth == 3 && elementName == "param" && currentName != nil && currentArgs[value] == nil {
                currentParam = value
                currentArgs[value] = ""
            } else {
                invalid = true; parser.abortParsing()
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if depth == 3, let param = currentParam {
                currentArgs[param, default: ""] += string
            } else if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                invalid = true; parser.abortParsing()
            }
        }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            guard let value = String(data: block, encoding: .utf8) else {
                invalid = true; parser.abortParsing(); return
            }
            self.parser(parser, foundCharacters: value)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if depth == 3 {
                currentParam = nil
            } else if depth == 2, let name = currentName {
                calls.append((name, currentArgs))
                currentName = nil
                currentArgs = [:]
            }
            depth -= 1
        }
    }

    // MARK: - LFM2/LFM3 Native Pythonic Calls

    private static func parseLFMPython(_ input: String, maxCalls: Int, repairedPrefix: Bool) throws -> ParsedTurn {
        var repaired = repairedPrefix
        let text = stripOuterMarkdownFence(input, didStrip: &repaired)
        let startMarker = "<|tool_call_start|>"
        let endMarker = "<|tool_call_end|>"

        var blocks: [(range: Range<String.Index>, body: String)] = []
        var cursor = text.startIndex
        while let open = text.range(of: startMarker, range: cursor..<text.endIndex) {
            let bodyStart = open.upperBound
            guard let close = text.range(of: endMarker, range: bodyStart..<text.endIndex) else {
                throw DirectorToolError.invalidCall("Unclosed <|tool_call_start|> block.")
            }
            blocks.append((open.lowerBound..<close.upperBound, String(text[bodyStart..<close.lowerBound])))
            cursor = close.upperBound
        }
        guard !blocks.isEmpty else {
            throw DirectorToolError.invalidCall("Malformed <|tool_call_start|> block.")
        }

        let leading = ToolCallText.stripFenceOpening(String(text[..<blocks[0].range.lowerBound]))
        let trailing = ToolCallText.stripFenceClosing(String(text[blocks.last!.range.upperBound...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty { repaired = true }

        var calls: [DirectorCall] = []
        for block in blocks {
            var scanner = PythonCallScanner(block.body)
            let parsed = try scanner.parseCallList()
            calls.append(contentsOf: parsed)
        }
        guard !calls.isEmpty else {
            throw DirectorToolError.invalidCall("Empty LFM tool call list.")
        }
        guard calls.count <= maxCalls else {
            throw DirectorToolError.invalidCall("Too many tool calls in one turn (maximum \(maxCalls)).")
        }
        return ParsedTurn(calls: calls, format: .lfmPython, narration: leading, repaired: repaired, droppedTrailing: trailing)
    }

    /// Safe, non-evaluating parser for `[func(arg="val", n=2), other(x=True)]`.
    private struct PythonCallScanner {
        private let chars: [Character]
        private var index = 0

        init(_ source: String) {
            self.chars = Array(source)
        }

        mutating func parseCallList() throws -> [DirectorCall] {
            skipWhitespace()
            let hasBrackets = peek() == "["
            if hasBrackets { advance() }
            var calls: [DirectorCall] = []
            skipWhitespace()
            if hasBrackets, peek() == "]" {
                advance()
                skipWhitespace()
                guard isAtEnd else { throw DirectorToolError.invalidCall("Unexpected trailing text in tool call list.") }
                return []
            }
            while !isAtEnd {
                calls.append(try parseSingleCall())
                skipWhitespace()
                if peek() == "," {
                    advance()
                    skipWhitespace()
                    if hasBrackets, peek() == "]" { break }
                    continue
                }
                break
            }
            if hasBrackets {
                skipWhitespace()
                guard peek() == "]" else { throw DirectorToolError.invalidCall("Expected ']' at end of tool call list.") }
                advance()
            }
            skipWhitespace()
            guard isAtEnd else { throw DirectorToolError.invalidCall("Unexpected trailing characters in tool call.") }
            return calls
        }

        private mutating func parseSingleCall() throws -> DirectorCall {
            skipWhitespace()
            let name = parseIdentifier()
            guard !name.isEmpty, name.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil else {
                throw DirectorToolError.invalidCall("Invalid tool name in call.")
            }
            guard ToolRegistry.isAllowedToolName(name) else {
                throw DirectorToolError.invalidCall("Unknown tool name: '\(name)'.")
            }
            skipWhitespace()
            guard peek() == "(" else { throw DirectorToolError.invalidCall("Expected '(' after \(name).") }
            advance()
            var args: [String: String] = [:]
            var raw: [String: String] = [:]
            skipWhitespace()
            if peek() != ")" {
                while !isAtEnd {
                    skipWhitespace()
                    let key = parseIdentifier()
                    guard !key.isEmpty, key.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil else {
                        throw DirectorToolError.invalidCall("Invalid parameter name in \(name).")
                    }
                    guard args[key] == nil else {
                        throw DirectorToolError.invalidCall("Duplicate argument: \(key).")
                    }
                    skipWhitespace()
                    guard peek() == "=" else { throw DirectorToolError.invalidCall("Expected '=' after \(key) in \(name).") }
                    advance()
                    skipWhitespace()
                    if let value = try parseValue() {
                        if ["sql", "code"].contains(key),
                           ["<parameter=", "<function=", "<tool_call"].contains(where: { value.contains($0) }) {
                            throw DirectorToolError.invalidCall("Nested tool tag inside \(key) parameter.")
                        }
                        args[key] = value
                        if ["old_text", "new_text"].contains(key) { raw[key] = value }
                    }
                    skipWhitespace()
                    if peek() == "," {
                        advance()
                        skipWhitespace()
                        if peek() == ")" { break }
                        continue
                    }
                    break
                }
            }
            skipWhitespace()
            guard peek() == ")" else { throw DirectorToolError.invalidCall("Expected ')' at end of \(name).") }
            advance()
            return DirectorCall(name: name, arguments: args, rawArguments: raw)
        }

        private mutating func parseValue() throws -> String? {
            guard let ch = peek() else { throw DirectorToolError.invalidCall("Missing argument value.") }
            if ch == "\"" || ch == "'" {
                return try parseQuotedString(quote: ch)
            }
            if ch == "[" || ch == "{" {
                return try parseBalancedLiteral()
            }
            // Bare token: integer, float, True/False/true/false, None/null.
            let start = index
            while let c = peek(), !c.isWhitespace, c != ",", c != ")" { advance() }
            let token = String(chars[start..<index])
            guard !token.isEmpty else { throw DirectorToolError.invalidCall("Missing argument value.") }
            switch token {
            case "None", "null": return nil
            case "True", "true": return "true"
            case "False", "false": return "false"
            default:
                if Double(token) != nil { return token }
                throw DirectorToolError.invalidCall("Unquoted value '\(token)' must be a string, number, or boolean.")
            }
        }

        private mutating func parseQuotedString(quote: Character) throws -> String {
            advance() // opening quote
            // Support Python triple-quoted strings ("""...""" or '''...''') too.
            let triple = peek() == quote && peek(offset: 1) == quote
            if triple { advance(); advance() }
            var result = ""
            while !isAtEnd {
                let c = chars[index]
                if triple {
                    if c == quote && peek(offset: 1) == quote && peek(offset: 2) == quote {
                        advance(); advance(); advance()
                        return result
                    }
                } else if c == quote {
                    advance()
                    return result
                }
                if c == "\\" {
                    advance()
                    guard let escaped = peek() else { throw DirectorToolError.invalidCall("Unterminated escape in string.") }
                    advance()
                    switch escaped {
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "\\": result.append("\\")
                    case "\"": result.append("\"")
                    case "'": result.append("'")
                    default: result.append(escaped)
                    }
                } else {
                    result.append(c)
                    advance()
                }
            }
            throw DirectorToolError.invalidCall("Unterminated string literal in tool call.")
        }

        private mutating func parseBalancedLiteral() throws -> String {
            let start = index
            var stack: [Character] = []
            while !isAtEnd {
                let c = chars[index]
                if c == "\"" || c == "'" {
                    _ = try parseQuotedString(quote: c)
                    continue
                }
                if c == "[" { stack.append("]") }
                else if c == "{" { stack.append("}") }
                else if c == "]" || c == "}" {
                    guard stack.last == c else { throw DirectorToolError.invalidCall("Mismatched bracket in argument.") }
                    stack.removeLast()
                    advance()
                    if stack.isEmpty { return String(chars[start..<index]) }
                    continue
                }
                advance()
            }
            throw DirectorToolError.invalidCall("Unclosed bracket in argument.")
        }

        private mutating func parseIdentifier() -> String {
            let start = index
            while let c = peek(), c.isASCII && (c.isLetter || c.isNumber || c == "_") { advance() }
            return String(chars[start..<index])
        }

        private mutating func skipWhitespace() {
            while let c = peek(), c.isWhitespace { advance() }
        }

        private var isAtEnd: Bool { index >= chars.count }
        private func peek(offset: Int = 0) -> Character? {
            let target = index + offset
            return target < chars.count ? chars[target] : nil
        }
        private mutating func advance() { index += 1 }
    }

    private static func stripOuterMarkdownFence(_ text: String, didStrip: inout Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"),
              let firstNewline = trimmed.firstIndex(of: "\n") else { return text }
        let inner = String(trimmed[trimmed.index(after: firstNewline)..<trimmed.index(trimmed.endIndex, offsetBy: -3)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return text }
        didStrip = true
        return inner
    }
}
