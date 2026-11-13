import SwiftUI

enum ChatBlock: Equatable {
    case text(String)
    case code(language: String, content: String)

    // Preserve code bytes, including indentation and its final newline. Closing
    // fences must match the opening character and be at least as long. Partial
    // streamed fences render as code without hiding their unfinished content.
    static func parse(_ source: String) -> [ChatBlock] {
        var blocks: [ChatBlock] = []
        var plain = ""
        var code = ""
        var open: (character: Character, length: Int, language: String)?
        let lines = source.components(separatedBy: "\n")
        func fence(_ line: String) -> (Character, Int, String)? {
            let indentation = line.prefix(while: { $0 == " " }).count
            guard indentation <= 3 else { return nil }
            let candidate = line.dropFirst(indentation)
            guard let first = candidate.first, first == "`" || first == "~" else { return nil }
            let length = candidate.prefix(while: { $0 == first }).count
            guard length >= 3 else { return nil }
            let suffix = candidate.dropFirst(length).trimmingCharacters(in: .whitespacesAndNewlines)
            return (first, length, suffix)
        }
        for (index, line) in lines.enumerated() {
            let original = String(line) + (index < lines.count - 1 ? "\n" : "")
            if let active = open {
                if let closing = fence(line), closing.0 == active.character,
                   closing.1 >= active.length, closing.2.isEmpty {
                    blocks.append(.code(language: active.language, content: code))
                    open = nil; code = ""
                } else { code += original }
            } else if let opening = fence(line), opening.0 != "`" || !opening.2.contains("`") {
                if !plain.isEmpty { blocks.append(.text(plain)); plain = "" }
                open = (opening.0, opening.1, String(opening.2.prefix(32)))
            } else { plain += original }
        }
        if let active = open { blocks.append(.code(language: active.language, content: code)) }
        if !plain.isEmpty { blocks.append(.text(plain)) }
        return blocks
    }
}

struct ChatMessageContent: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(ChatBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(text.trimmingCharacters(in: .newlines)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let language, let content):
                    ChatCodeBlock(language: language, content: content)
                }
            }
        }
    }
}

private struct ChatCodeBlock: View {
    let language: String
    let content: String
    @State private var copied = false
    @State private var feedback: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "CODE" : language.uppercased())
                    .font(.caption2.weight(.semibold)).tracking(1)
                    .foregroundStyle(KeelStyle.accent)
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = content
                    feedback?.cancel(); copied = true
                    feedback = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        if !Task.isCancelled { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium)).frame(minHeight: 44)
                }.buttonStyle(.plain).accessibilityLabel(copied ? "Code copied" : "Copy code")
            }.padding(.horizontal, 14)
            Divider()
            ScrollView(.horizontal) {
                Text(content).font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false).textSelection(.enabled).padding(14)
            }.accessibilityIdentifier("chatCodeContent")
        }
        .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(KeelStyle.accent.opacity(0.18)))
        .onChange(of: content) { _, _ in feedback?.cancel(); copied = false }
        .onDisappear { feedback?.cancel() }
    }
}
