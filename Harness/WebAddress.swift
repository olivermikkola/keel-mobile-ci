import Foundation

/// Which web pages `read_url` may open in a chat: only addresses the user
/// wrote in their own messages. File contents, tool results and earlier
/// replies are untrusted; if they could choose an address, a planted line
/// could send the chat's files out in a query string.
enum WebAddress {
    /// Match a complete address from user text. Host names ignore case;
    /// paths and queries do not. A missing root slash is equivalent, and a
    /// bare domain may use HTTP or HTTPS. An explicit scheme must be kept.
    static func userWrote(_ address: String, in userMessages: [String]) -> Bool {
        guard let requested = canonical(address) else { return false }
        let pattern = #"(?i)(?<![\p{L}\p{N}_@./-])(?:https?://[^\s<>"`]+|(?:[\p{L}\p{N}-]+\.)+[\p{L}\p{N}-]+(?::[0-9]+)?(?:[/?#][^\s<>"`]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        for message in userMessages {
            for match in regex.matches(in: message, range: NSRange(message.startIndex..., in: message)) {
                guard let range = Range(match.range, in: message) else { continue }
                var candidate = String(message[range])
                // Prose punctuation and a Markdown wrapper are not part of a link.
                while let last = candidate.last, ".,;!".contains(last) { candidate.removeLast() }
                for (opening, closing) in [("(", ")"), ("[", "]"), ("{", "}")] {
                    while candidate.hasSuffix(closing),
                          candidate.filter({ String($0) == closing }).count > candidate.filter({ String($0) == opening }).count {
                        candidate.removeLast()
                    }
                }
                let explicitScheme = candidate.range(of: #"\Ahttps?://"#, options: .regularExpression.union(.caseInsensitive)) != nil
                if !explicitScheme { candidate = requested.scheme + "://" + candidate }
                if canonical(candidate) == requested { return true }
            }
        }
        return false
    }

    private struct Address: Equatable {
        let scheme: String
        let host: String
        let port: Int
        let path: String
        let query: String?
    }

    private static func canonical(_ text: String) -> Address? {
        guard let url = try? ReadURL.validatedURL(text),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased() else { return nil }
        return Address(scheme: scheme, host: host, port: parts.port ?? (scheme == "https" ? 443 : 80),
                       path: parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath,
                       query: parts.percentEncodedQuery)
    }

    static let refusal = "Not opened: read_url opens only web addresses the user wrote in this chat. Ask the user for the address."
}

extension ReadURLError: LocalizedError {
    /// Read by the model after a failed read_url, so each says what to do next.
    var errorDescription: String? {
        switch self {
        case .url: return "That is not a web address read_url can open: use http or https, with no sign-in details."
        case .response: return "The site answered with an error or a redirect, so nothing was read. A moved page must be opened at its new address, which the user needs to give."
        case .tooLarge: return "The page is larger than 512 KB, so it was not read."
        case .contentType: return "That address is not a web page or plain text, so it was not read."
        case .encoding: return "The page is not UTF-8 text, so it was not read."
        }
    }
}
