import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// Result of a fast local syntax check on a proposed file edit before user review.
public struct SyntaxCheckResult: Equatable, Sendable {
    public let isValid: Bool
    public let message: String

    public init(isValid: Bool, message: String) {
        self.isValid = isValid
        self.message = message
    }
}

/// Runs deterministic, sandboxed syntax checks on full post-edit text without WasmKit.
public enum SyntaxCheck {
    public static func inspect(path: String, text: String) -> SyntaxCheckResult? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "json", "geojson", "webmanifest":
            return checkJSON(text)
        case "css":
            return checkCSSBraces(text)
        case "js", "cjs":
            return checkJavaScript(text)
        case "html", "htm":
            return checkHTMLBlocks(text)
        default:
            return nil
        }
    }

    /// Checks inline `<style>` and `<script>` blocks inside HTML files (Websites / Slides)
    /// without rejecting valid void tags like `<br>` or `<img>`. Plain HTML without
    /// `<style>` or `<script>` returns `nil`.
    private static func checkHTMLBlocks(_ text: String) -> SyntaxCheckResult? {
        guard text.range(of: "<style", options: .caseInsensitive) != nil
            || text.range(of: "<script", options: .caseInsensitive) != nil else { return nil }
        var checkedAny = false

        // Validate every `<style ...>...</style>` block.
        if let styleResult = inspectTagBlocks(in: text, tag: "style", validate: { _, body in
            checkedAny = true
            let result = checkCSSBraces(body)
            return result.isValid ? nil : SyntaxCheckResult(isValid: false, message: "HTML <style> \(result.message)")
        }) {
            return styleResult
        }

        // Validate every inline `<script ...>...</script>` block.
        if let scriptResult = inspectTagBlocks(in: text, tag: "script", validate: { openTag, body in
            let lowerOpen = openTag.lowercased()
            // External scripts (`src=...`) have no inline body to check.
            if lowerOpen.contains("src=") { return nil }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if lowerOpen.contains("application/json") || lowerOpen.contains("application/ld+json") || lowerOpen.contains("importmap") {
                checkedAny = true
                let result = checkJSON(trimmed)
                return result.isValid ? nil : SyntaxCheckResult(isValid: false, message: "HTML <script> \(result.message)")
            }
            if lowerOpen.contains("type=") && !lowerOpen.contains("javascript") && !lowerOpen.contains("module") {
                return nil
            }
            if let js = checkJavaScript(trimmed) {
                checkedAny = true
                return js.isValid ? nil : SyntaxCheckResult(isValid: false, message: "HTML <script> \(js.message)")
            }
            return nil
        }) {
            return scriptResult
        }

        return checkedAny ? SyntaxCheckResult(isValid: true, message: "HTML styles and scripts valid") : nil
    }

    private static func inspectTagBlocks(
        in text: String,
        tag: String,
        validate: (String, String) -> SyntaxCheckResult?
    ) -> SyntaxCheckResult? {
        let openPrefix = "<" + tag
        let closeToken = "</" + tag + ">"
        var cursor = text.startIndex
        while let start = text.range(of: openPrefix, options: .caseInsensitive, range: cursor..<text.endIndex) {
            let afterName = start.upperBound
            if afterName < text.endIndex {
                let next = text[afterName]
                guard next == ">" || next.isWhitespace || next == "/" else {
                    cursor = afterName
                    continue
                }
            }
            guard let tagEnd = text.range(of: ">", range: afterName..<text.endIndex) else {
                return SyntaxCheckResult(isValid: false, message: "HTML syntax error: unclosed <\(tag)> tag.")
            }
            let openTag = String(text[start.lowerBound..<tagEnd.upperBound])
            guard let close = text.range(of: closeToken, options: .caseInsensitive, range: tagEnd.upperBound..<text.endIndex) else {
                return SyntaxCheckResult(isValid: false, message: "HTML syntax error: missing closing </\(tag)> tag.")
            }
            let body = String(text[tagEnd.upperBound..<close.lowerBound])
            if let failure = validate(openTag, body) {
                return failure
            }
            cursor = close.upperBound
        }
        return nil
    }

    private static func checkJSON(_ text: String) -> SyntaxCheckResult {
        guard let data = text.data(using: .utf8) else {
            return SyntaxCheckResult(isValid: false, message: "JSON check: file is not valid UTF-8.")
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return SyntaxCheckResult(isValid: true, message: "JSON syntax valid")
        } catch {
            return SyntaxCheckResult(isValid: false, message: "JSON syntax error: \(error.localizedDescription)")
        }
    }

    private static func checkCSSBraces(_ text: String) -> SyntaxCheckResult {
        var depth = 0
        var quote: Character?
        var inComment = false
        var escaped = false
        var previous: Character?

        for ch in text {
            if inComment {
                if previous == "*" && ch == "/" {
                    inComment = false
                    previous = nil
                } else {
                    previous = ch
                }
                continue
            }
            if let q = quote {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == q {
                    quote = nil
                }
                previous = ch
                continue
            }
            if previous == "/" && ch == "*" {
                inComment = true
                previous = nil
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth < 0 {
                    return SyntaxCheckResult(isValid: false, message: "CSS syntax error: unexpected closing '}'.")
                }
            }
            previous = ch
        }

        if inComment {
            return SyntaxCheckResult(isValid: false, message: "CSS syntax error: unclosed /* ... */ comment.")
        }
        if let quote {
            return SyntaxCheckResult(isValid: false, message: "CSS syntax error: unclosed \(quote) string.")
        }
        if depth > 0 {
            return SyntaxCheckResult(isValid: false, message: "CSS syntax error: missing \(depth) closing '}'.")
        }
        return SyntaxCheckResult(isValid: true, message: "CSS braces and strings balanced")
    }

    private static func checkJavaScript(_ text: String) -> SyntaxCheckResult? {
        #if canImport(JavaScriptCore)
        // `new Function(src)` parses classic scripts without executing them,
        // but rejects top-level ES module `import`/`export` statements.
        let trimmedLines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if trimmedLines.contains(where: { $0.hasPrefix("import ") || $0.hasPrefix("export ") }) {
            return nil
        }
        guard let context = JSContext() else { return nil }
        var syntaxError: String?
        context.exceptionHandler = { _, exception in
            syntaxError = exception?.toString()
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: [text], options: []),
              let jsonArray = String(data: encoded, encoding: .utf8),
              jsonArray.count >= 2 else {
            return nil
        }
        let quoted = String(jsonArray.dropFirst().dropLast())
        _ = context.evaluateScript("new Function(\(quoted));")
        if let syntaxError {
            return SyntaxCheckResult(isValid: false, message: "JavaScript syntax error: \(syntaxError)")
        }
        return SyntaxCheckResult(isValid: true, message: "JavaScript syntax valid")
        #else
        return nil
        #endif
    }
}
