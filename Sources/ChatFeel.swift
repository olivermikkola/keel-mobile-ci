import SwiftUI

/// How a file the agent is making should look in the chat, before it is opened.
enum WorkLook {
    struct Spec {
        let kind: WorkPreviewCard.Kind
        let buildingTitle: String
        let doneTitle: String
        let footer: String
        let symbol: String
    }

    static func spec(path: String, study: Bool) -> Spec? {
        let file = (path as NSString).lastPathComponent.lowercased()
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            if file.contains("slide") {
                return Spec(kind: .slides, buildingTitle: "Building the slides", doneTitle: "Slides", footer: "Slides", symbol: "rectangle.on.rectangle.angled")
            }
            return Spec(kind: .website, buildingTitle: "Building the website", doneTitle: "Website", footer: "Website", symbol: "macwindow")
        }
        if ext == "csv" {
            return Spec(kind: .spreadsheet, buildingTitle: "Creating a spreadsheet", doneTitle: "Spreadsheet", footer: "Spreadsheet", symbol: "tablecells")
        }
        if ext == "md" || ext == "markdown" {
            if study {
                return Spec(kind: .cards, buildingTitle: "Making the cards", doneTitle: "Cards", footer: "Study", symbol: "rectangle.on.rectangle.angled")
            }
            return Spec(kind: .document, buildingTitle: "Creating a document", doneTitle: "Document", footer: "Document", symbol: "doc.richtext")
        }
        return nil
    }

    /// "Propose create · index.html" → "index.html". Leaves search labels alone.
    static func path(from activity: String) -> String? {
        guard activity.hasPrefix("Propose ") || activity.hasPrefix("Make an image") else { return nil }
        guard let mark = activity.range(of: " · ") else { return nil }
        let rest = activity[mark.upperBound...].split(separator: "→", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard rest.contains(".") else { return nil }
        return rest
    }

    /// One human line for a tool step. The raw activity stays available for tests.
    static func stepTitle(_ activity: String, busy: Bool, failed: Bool = false) -> String {
        if activity.hasPrefix("Propose create") {
            let name = namedFile(activity) ?? "a file"
            if failed { return "Couldn't create \(name)" }
            return busy ? "Creating \(name)" : "Created \(name)"
        }
        if activity.hasPrefix("Propose edit") {
            let name = namedFile(activity) ?? "a file"
            if failed { return "Couldn't edit \(name)" }
            return busy ? "Editing \(name)" : "Edited \(name)"
        }
        if activity.hasPrefix("Propose delete") {
            let name = namedFile(activity) ?? "a file"
            if failed { return "Couldn't remove \(name)" }
            return busy ? "Removing \(name)" : "Removed \(name)"
        }
        if activity.hasPrefix("Propose rename") {
            let name = namedFile(activity) ?? "a file"
            if failed { return "Couldn't rename \(name)" }
            return busy ? "Renaming \(name)" : "Renamed \(name)"
        }
        if activity.hasPrefix("Make an image") {
            if failed { return "Couldn't make an image" }
            return busy ? "Making an image" : "Made an image"
        }
        if activity.hasPrefix("Search the web") {
            if failed { return "Web search failed" }
            return busy ? "Searching the web" : "Searched the web"
        }
        if activity.hasPrefix("Read web page") {
            if failed { return "Couldn't read web page" }
            return busy ? "Reading a web page" : "Read a web page"
        }
        if activity.hasPrefix("Look at your GitHub") {
            if failed { return "Couldn't list GitHub repositories" }
            return busy ? "Listing GitHub repositories" : "Listed GitHub repositories"
        }
        if activity.hasPrefix("Open "), activity.contains("GitHub") {
            if failed { return "Couldn't open GitHub repository" }
            return busy ? "Opening a GitHub repository" : "Opened a GitHub repository"
        }
        if activity.hasPrefix("Search ") {
            let target = String(activity.dropFirst("Search ".count)).split(separator: "·").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? "files"
            let name = (target as NSString).lastPathComponent
            let shown = name.isEmpty ? "files" : name
            if failed { return "Couldn't search \(shown)" }
            return busy ? "Searching \(shown)" : "Searched \(shown)"
        }
        if activity.hasPrefix("Read ") {
            let target = String(activity.dropFirst("Read ".count)).split(separator: "·").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? "a file"
            let name = (target as NSString).lastPathComponent
            let shown = name.isEmpty ? "a file" : name
            if failed { return "Couldn't read \(shown)" }
            return busy ? "Reading \(shown)" : "Read \(shown)"
        }
        if activity.hasPrefix("List ") {
            if failed { return "Couldn't list files" }
            return busy ? "Listing files" : "Listed files"
        }
        if activity.hasPrefix("Run SQL") {
            if failed { return "Query failed" }
            return busy ? "Running a query" : "Ran a query"
        }
        if activity.hasPrefix("Run JavaScript") {
            if failed { return "Code failed" }
            return busy ? "Running code" : "Ran code"
        }
        if activity.hasPrefix("Remember") {
            if failed { return "Couldn't save memory" }
            return busy ? "Saving a memory" : "Saved a memory"
        }
        if activity.hasPrefix("Look through earlier") {
            if failed { return "Couldn't search earlier chats" }
            return busy ? "Searching earlier chats" : "Searched earlier chats"
        }
        if activity.hasPrefix("Run CI") {
            if failed { return "Couldn't start checks" }
            return busy ? "Starting checks" : "Started checks"
        }
        if activity.hasPrefix("Create Pull Request") {
            if failed { return "Couldn't prepare pull request" }
            return busy ? "Preparing a pull request" : "Prepared a pull request"
        }
        if failed { return "Couldn't complete: \(activity)" }
        return activity
    }

    private static func namedFile(_ activity: String) -> String? {
        guard let mark = activity.range(of: " · ") else { return nil }
        let rest = activity[mark.upperBound...].split(separator: "→", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !rest.isEmpty else { return nil }
        return (rest as NSString).lastPathComponent
    }
}

/// The thing being made, drawn as a quiet preview instead of a file path.
struct WorkPreviewCard: View {
    enum Kind { case website, spreadsheet, document, slides, cards }

    let title: String
    let footer: String
    let symbol: String
    let kind: Kind
    /// Nil while the agent is still writing. 1 when the file is ready to open.
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.bottom, 10)
            skeleton
                .frame(maxWidth: .infinity)
                .frame(height: 168)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(KeelStyle.accent)
                        .scaleEffect(x: CGFloat(min(max(progress ?? 0.28, 0.08), 1)), y: 1, anchor: .leading)
                }
                .clipShape(Capsule())
                .padding(.top, 12)
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(KeelStyle.accent)
                Text(footer).font(.subheadline.weight(.medium))
            }
            .padding(.top, 10)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(KeelStyle.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(footer)")
    }

    @ViewBuilder private var skeleton: some View {
        switch kind {
        case .website: website
        case .spreadsheet: spreadsheet
        case .document, .cards: document
        case .slides: slides
        }
    }

    private var website: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(Color.primary.opacity(0.2)).frame(width: 7, height: 7)
                Circle().fill(Color.primary.opacity(0.14)).frame(width: 7, height: 7)
                Circle().fill(Color.primary.opacity(0.14)).frame(width: 7, height: 7)
                Capsule().fill(Color.primary.opacity(0.08)).frame(width: 92, height: 8)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Capsule().fill(KeelStyle.accent.opacity(0.85)).frame(width: 18, height: 18)
                    Capsule().fill(Color.primary.opacity(0.16)).frame(width: 120, height: 8)
                    Capsule().fill(Color.primary.opacity(0.10)).frame(width: 148, height: 8)
                    Capsule().fill(Color.primary.opacity(0.10)).frame(width: 96, height: 8)
                }
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(maxWidth: .infinity)
                    .frame(height: 88)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var spreadsheet: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { _ in
                    Capsule().fill(Color.primary.opacity(0.14)).frame(height: 8)
                }
            }
            ForEach(0..<5, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { column in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(row == 2 && column == 3 ? KeelStyle.accent : Color.primary.opacity(0.08))
                            .frame(height: 14)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var document: some View {
        VStack(alignment: .leading, spacing: 8) {
            Capsule().fill(Color.primary.opacity(0.18)).frame(width: 150, height: 10)
            Capsule().fill(Color.primary.opacity(0.10)).frame(maxWidth: .infinity).frame(height: 8)
            Capsule().fill(Color.primary.opacity(0.10)).frame(width: 210, height: 8)
            Capsule().fill(Color.primary.opacity(0.10)).frame(width: 168, height: 8)
            Spacer(minLength: 8)
            Capsule().fill(Color.primary.opacity(0.18)).frame(width: 96, height: 10)
            Capsule().fill(Color.primary.opacity(0.10)).frame(maxWidth: .infinity).frame(height: 8)
            Capsule().fill(Color.primary.opacity(0.10)).frame(width: 180, height: 8)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var slides: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule().fill(Color.primary.opacity(0.2)).frame(width: 132, height: 12)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 8) {
                        Circle().fill(KeelStyle.accent.opacity(0.8)).frame(width: 7, height: 7)
                        Capsule().fill(Color.primary.opacity(0.12)).frame(width: CGFloat(120 + index * 24), height: 8)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }
}

/// "Thinking · 3s", collapsed. The phase is one tap away, not a second status bar.
struct ThinkingStatusLine: View {
    let phase: String
    let started: Date
    @State private var open = false

    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(started)))
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                    HStack(spacing: 4) {
                        Text("Thinking · \(seconds)s")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("prefillProgress")
                .accessibilityLabel("Thinking for \(seconds) seconds")
                .accessibilityValue(phase)
                if open {
                    Text(phase.isEmpty ? "Working on this \(KeelDevice.name)." : phase)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
