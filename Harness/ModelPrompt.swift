import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum ModelFamily: String, Codable, Sendable {
    case bonsai, lfm3, miniCPM5

    var addsTokenizerSpecialTokens: Bool { self == .bonsai }
    var sampling: SamplingProfile {
        switch self {
        case .bonsai: return .app
        case .lfm3:
            return SamplingProfile(name: "LFM3", temperature: 0.1, topK: 50, topP: 1,
                                   minP: 0, repeatPenalty: 1.1)
        case .miniCPM5:
            return SamplingProfile(name: "MiniCPM5", temperature: 1.0, topK: 0, topP: 0.95, minP: 0)
        }
    }
}

/// Each renderer follows its model's native template with thinking disabled.
/// The two new templates retain empty thinking markers across user turns.
enum ModelPrompt {
    static let mediaMarker = "<__media__>"
    static let miniCPMCallFormat = """
    Call one function at a time, with no text after it:
    <function name="example_function_name"><param name="example_parameter">value</param></function>
    For values containing <, & or newlines use CDATA: <param name="code"><![CDATA[console.log(1 < 2)]]></param>
    Do not claim a tool ran until you receive its result.
    """

    static func render(family: ModelFamily, system: String, messages: [(role: String, text: String)], imageCounts: [Int] = []) -> String {
        if family == .bonsai { return AgentPrompt.chatML(system: system, messages: messages) }
        func data(_ value: String) -> String {
            value.replacingOccurrences(of: "<|", with: "< |")
                .replacingOccurrences(of: "<s>", with: "< s>")
                .replacingOccurrences(of: "</s>", with: "</ s>")
                .replacingOccurrences(of: "<tool_response>", with: "< tool_response>")
                .replacingOccurrences(of: "</tool_response>", with: "</ tool_response>")
                .replacingOccurrences(of: mediaMarker, with: "< __media__>")
        }
        var instructions = family == .miniCPM5
            ? system.replacingOccurrences(of: AgentPrompt.callFormat, with: miniCPMCallFormat) : system
        if family == .miniCPM5 {
            instructions = instructions.replacingOccurrences(of: "XML-escape &lt; and &amp; if needed.",
                with: "Use CDATA around values containing <, & or newlines.")
        }
        if family == .lfm3 {
            instructions = instructions.components(separatedBy: "\n").map { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let function = object["function"] as? [String: Any],
                      let bytes = try? JSONSerialization.data(withJSONObject: function, options: [.sortedKeys]),
                      let flat = String(data: bytes, encoding: .utf8) else { return line }
                return flat
            }.joined(separator: "\n")
        }
        var result = family == .lfm3 ? "<|startoftext|>" : "<s>"
        result += "<|im_start|>system\n\(instructions)<|im_end|>\n"
        for (index, message) in messages.enumerated() {
            let native = family == .miniCPM5 && message.role == "assistant"
                ? NativeToolCall.renderCanonical(message.text) : message.text
            let content = data(native)
            if family == .miniCPM5 && message.role == "tool" {
                if index == 0 || messages[index - 1].role != "tool" { result += "<|im_start|>user" }
                result += "\n<tool_response>\n\(content)\n</tool_response>"
                if index == messages.count - 1 || messages[index + 1].role != "tool" { result += "<|im_end|>\n" }
            } else {
                result += "<|im_start|>\(message.role)\n"
                if message.role == "assistant" {
                    result += family == .lfm3 ? "<think></think>" : "<think>\n\n</think>\n\n"
                }
                if message.role == "tool" { result += "<tool_response>\n\(content)\n</tool_response>" }
                else {
                    result += content
                    if family == .lfm3, index < imageCounts.count {
                        result += String(repeating: "\n" + mediaMarker, count: imageCounts[index])
                    }
                }
                result += "<|im_end|>\n"
            }
        }
        result += "<|im_start|>assistant\n"
        return result + (family == .lfm3 ? "<think></think>" : "<think>\n\n</think>\n\n")
    }
}

/// Convert MiniCPM's native XML into the existing strict tool protocol.
/// This grants no authority: the normal parser, limits and approval gates follow.
enum NativeToolCall {
    static func normalize(_ output: String, family: ModelFamily) throws -> String {
        guard family == .miniCPM5, output.contains("<function") || output.contains("<param") else { return output }
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), let line = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: line)..<text.index(text.endIndex, offsetBy: -3)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.utf8.count <= 96 * 1024, let start = text.range(of: "<function"),
              !text[..<start.lowerBound].contains("<") else {
            throw DirectorToolError.invalidCall("Malformed native tool call.")
        }
        let parser = XMLParser(data: Data(("<keel_native_call>" + text[start.lowerBound...] + "</keel_native_call>").utf8))
        let reader = Reader(); parser.delegate = reader; parser.shouldResolveExternalEntities = false
        guard parser.parse(), !reader.invalid, reader.depth == 0, let name = reader.name else {
            throw DirectorToolError.invalidCall("Malformed native tool call.")
        }
        let canonical = canonicalCall(name: name, arguments: reader.arguments)
        _ = try DirectorCall.parse(canonical)
        return canonical
    }

    private static func canonicalCall(name: String, arguments: [String: String]) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var canonical = "<tool_call>\n<function=\(name)>"
        for (key, value) in arguments.sorted(by: { $0.key < $1.key }) {
            let encoded = ["path", "destination_path"].contains(key) ? value : escape(value)
            let padding = ["code", "sql", "old_text", "new_text"].contains(key) ? "\n" : ""
            canonical += "\n<parameter=\(key)>\(padding)\(encoded)\(padding)</parameter>"
        }
        return canonical + "\n</function>\n</tool_call>"
    }

    static func renderCanonical(_ text: String) -> String {
        guard let call = try? DirectorCall.parse(text) else { return text }
        let parameters = call.arguments.sorted(by: { $0.key < $1.key }).map { key, value in
            let escaped = value.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
            return "<param name=\"\(key)\"><![CDATA[\(escaped)]]></param>"
        }.joined()
        return "<function name=\"\(call.name)\">\(parameters)</function>"
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var depth = 0, invalid = false
        var name: String?, parameter: String?
        var arguments: [String: String] = [:]
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            if depth == 1 {
                guard elementName == "keel_native_call", attributes.isEmpty else { invalid = true; parser.abortParsing(); return }
                return
            }
            guard attributes.count == 1, let value = attributes["name"],
                  value.range(of: "^[a-z_]+$", options: .regularExpression) != nil else { invalid = true; parser.abortParsing(); return }
            if depth == 2 && elementName == "function" && name == nil { name = value }
            else if depth == 3 && elementName == "param" && arguments[value] == nil {
                parameter = value; arguments[value] = ""
            } else { invalid = true; parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if depth == 3, let parameter { arguments[parameter, default: ""] += string }
            else if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { invalid = true }
        }
        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            guard let value = String(data: block, encoding: .utf8) else { invalid = true; return }
            self.parser(parser, foundCharacters: value)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if depth == 3 { parameter = nil }; depth -= 1
        }
    }
}
