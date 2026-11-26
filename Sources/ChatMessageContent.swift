import SwiftUI
#if canImport(KeelHarness)
import KeelHarness
#endif

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

struct ChatMessageContent: View, Equatable {
    let text: String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text }

    var body: some View {
        let blocks = ChatMessageRenderCache.blocks(for: text)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let proseBlocks):
                    ProseView(blocks: proseBlocks)
                case .code(let language, let content):
                    ChatCodeBlock(language: language, content: content)
                }
            }
        }
    }
}

/// Bounded in-memory caches for parsed Markdown blocks and styled inline runs.
/// `NSCache` automatically evicts under iOS memory pressure while avoiding
/// repeated Markdown parsing when finished messages re-appear during streaming.
@MainActor
private enum ChatMessageRenderCache {
    enum ParsedBlock {
        case text([ProseBlock])
        case code(language: String, content: String)
    }

    private final class BlocksBox {
        let value: [ParsedBlock]
        init(_ value: [ParsedBlock]) { self.value = value }
    }

    private final class InlineBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let blockCache: NSCache<NSString, BlocksBox> = {
        let cache = NSCache<NSString, BlocksBox>()
        cache.countLimit = 128
        return cache
    }()

    private static let inlineCache: NSCache<NSString, InlineBox> = {
        let cache = NSCache<NSString, InlineBox>()
        cache.countLimit = 256
        cache.totalCostLimit = 2_000_000
        return cache
    }()

    static func blocks(for source: String) -> [ParsedBlock] {
        let key = source as NSString
        if let hit = blockCache.object(forKey: key) { return hit.value }
        let parsed: [ParsedBlock] = ChatBlock.parse(source).map { block in
            switch block {
            case .text(let text): return .text(ProseBlock.parse(text))
            case .code(let language, let content): return .code(language: language, content: content)
            }
        }
        blockCache.setObject(BlocksBox(parsed), forKey: key)
        return parsed
    }

    static func inline(for text: String, build: (String) -> AttributedString) -> AttributedString {
        let key = text as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.value }
        let built = build(text)
        inlineCache.setObject(InlineBox(built), forKey: key, cost: max(1, text.utf8.count))
        return built
    }
}

/// A reply's prose as headings, paragraphs, lists, quotes and tables. Bold,
/// italic and inline code are drawn; nothing in it is a link or runs anything.
private struct ProseView: View {
    let blocks: [ProseBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(Self.inline(text))
                        .font(level <= 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
                        .padding(.top, 4).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                case .paragraph(let text):
                    Text(Self.inline(text)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .list(let items):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.marker).font(.body.monospacedDigit())
                                    .foregroundStyle(KeelStyle.accent).frame(minWidth: 18, alignment: .trailing)
                                Text(Self.inline(item.text)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.leading, CGFloat(item.depth) * 18)
                        }
                    }
                case .quote(let text):
                    Text(Self.inline(text)).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 14)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5).fill(KeelStyle.accent.opacity(0.6)).frame(width: 3)
                        }
                case .table(let header, let rows):
                    ProseTable(header: header, rows: rows)
                case .rule:
                    Divider().padding(.vertical, 2)
                }
            }
        }
    }

    /// Bold, italic and inline code from Markdown; anything it cannot read is shown as written.
    @MainActor
    static func inline(_ text: String) -> AttributedString {
        ChatMessageRenderCache.inline(for: text) { raw in
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                                  failurePolicy: .returnPartiallyParsedIfPossible)
            guard var styled = try? AttributedString(markdown: ProseBlock.inlineSafe(raw), options: options) else {
                return AttributedString(raw)
            }
            for run in styled.runs where run.inlinePresentationIntent?.contains(.code) == true {
                styled[run.range].swiftUI.font = Font.system(.callout, design: .monospaced)
                styled[run.range].swiftUI.backgroundColor = KeelStyle.accent.opacity(0.12)
            }
            return styled
        }
    }
}

/// A table that scrolls sideways when it is wider than the screen.
private struct ProseTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(ProseView.inline(cell)).font(.subheadline.weight(.semibold))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(ProseView.inline(cell)).font(.subheadline)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(14)
        }
        .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: KeelStyle.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: KeelStyle.cardRadius, style: .continuous).strokeBorder(KeelStyle.hairline))
        .accessibilityIdentifier("chatTable")
    }
}

private struct ChatCodeBlock: View {
    let language: String
    let content: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "CODE" : language.uppercased())
                    .font(.caption2.weight(.semibold)).tracking(1)
                    .foregroundStyle(KeelStyle.accent)
                Spacer(minLength: 8)
                Button {
                    // Pasteboard sync can block for seconds on slow hosts;
                    // the chat must never wait on it.
                    let text = content
                    Task.detached(priority: .userInitiated) { UIPasteboard.general.string = text }
                    copied = true
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
        .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: KeelStyle.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: KeelStyle.cardRadius, style: .continuous).strokeBorder(KeelStyle.hairline))
        // The confirmation stays while the block is on screen, so slow devices
        // still show it; scrolling away or a new reply resets it.
        .onChange(of: content) { _, _ in copied = false }
        .onDisappear { copied = false }
    }
}
