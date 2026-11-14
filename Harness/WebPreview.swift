import Foundation

/// Turns an HTML file from the task workspace into one self-contained page for
/// the on-phone preview. Local stylesheets and scripts are inlined, and a
/// Content Security Policy goes first so the page cannot reach the network,
/// open frames or submit forms. Anything the page still links to elsewhere is
/// left in place and blocked by that policy.
public enum WebPreview {
    public static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'unsafe-inline'",
        "style-src 'unsafe-inline'",
        "img-src data: blob:",
        "font-src data:",
        "media-src data: blob:",
        "connect-src 'none'",
        "frame-src 'none'",
        "object-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
    ].joined(separator: "; ")

    public static func isPage(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".html") || lower.hasSuffix(".htm")
    }

    /// `read` returns a workspace file's text, or nil if there is none.
    public static func document(html: String, path: String, read: (String) -> String?) -> String {
        var page = html
        page = replace(stylesheet, in: page) { tag, href in
            guard let target = resolve(href, from: path), let css = read(target) else { return tag }
            return "<style>\n" + css.replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive) + "\n</style>"
        }
        page = replace(script, in: page) { tag, src in
            guard let target = resolve(src, from: path), let js = read(target) else { return tag }
            return "<script>\n" + js.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive) + "\n</script>"
        }
        // The policy covers only what comes after it, so it goes before everything
        // except the doctype (which must stay first to keep standards mode).
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">"
        if let doctype = page.range(of: #"^\s*<!doctype[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            page.insert(contentsOf: meta, at: doctype.upperBound)
        } else {
            page = meta + page
        }
        return page
    }

    /// A workspace path for a link in the page at `from`, or nil for anything that
    /// is not a file in the workspace (other sites, data: URLs, paths above the root).
    static func resolve(_ link: String, from page: String) -> String? {
        var link = link.trimmingCharacters(in: .whitespaces)
        if let cut = link.firstIndex(where: { $0 == "?" || $0 == "#" }) { link = String(link[..<cut]) }
        guard !link.isEmpty, !link.hasPrefix("//"),
              link.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) == nil,
              let decoded = link.removingPercentEncoding else { return nil }
        var parts: [Substring] = decoded.hasPrefix("/") ? [] : page.split(separator: "/").dropLast()
        for part in decoded.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if parts.popLast() == nil { return nil }
            default: parts.append(part)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    private static let stylesheet = try! NSRegularExpression(
        pattern: #"<link\b(?=[^>]*\brel\s*=\s*["']?stylesheet\b)[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>"#,
        options: [.caseInsensitive])
    private static let script = try! NSRegularExpression(
        pattern: #"<script\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>\s*</script\s*>"#,
        options: [.caseInsensitive])

    private static func replace(_ regex: NSRegularExpression, in text: String,
                                with transform: (_ tag: String, _ link: String) -> String) -> String {
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let link = (1...3).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }
                .map { source.substring(with: $0) } ?? ""
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            result += transform(source.substring(with: match.range), link)
            last = match.range.location + match.range.length
        }
        return result + source.substring(from: last)
    }
}
