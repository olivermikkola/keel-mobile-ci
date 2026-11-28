import SwiftUI
import WidgetKit

/// Home Screen and Lock Screen widget: one tap opens a new Keel chat with the
/// keyboard up (`keelmobile://new`). It shows no chat content, so it needs no
/// shared data and no App Group.
@main
struct KeelWidgetBundle: WidgetBundle {
    var body: some Widget { AskKeelWidget() }
}

struct AskKeelWidget: Widget {
    static let newChat = URL(string: "keelmobile://new")!

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AskKeel", provider: Provider()) { _ in
            AskKeelView()
                .containerBackground(for: .widget) { Color(red: 10.0 / 255.0, green: 17.0 / 255.0, blue: 18.0 / 255.0) }
                .widgetURL(Self.newChat)
        }
        .configurationDisplayName("Ask Keel")
        .description("Start a new chat. The model runs on this iPhone.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }

    struct Entry: TimelineEntry { let date: Date }

    /// Nothing changes over time, so there is one entry and no refresh.
    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry { Entry(date: .now) }
        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now)) }
        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            completion(Timeline(entries: [Entry(date: .now)], policy: .never))
        }
    }
}

struct AskKeelView: View {
    @Environment(\.widgetFamily) private var family
    private let jade = Color(red: 54.0 / 255.0, green: 179.0 / 255.0, blue: 148.0 / 255.0)

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                KeelMark().padding(9).widgetAccentable()
            }
            .accessibilityLabel("Ask Keel")
        case .accessoryRectangular:
            HStack(spacing: 8) {
                KeelMark().frame(width: 26, height: 26).widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ask Keel").font(.headline)
                    Text("On this iPhone").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                KeelMark().frame(width: 40, height: 40)
                Spacer(minLength: 0)
                Text("Ask Keel").font(.headline).foregroundStyle(.white)
                HStack(spacing: 5) {
                    Image(systemName: "square.and.pencil").font(.caption.weight(.semibold))
                    Text("New chat").font(.caption.weight(.medium))
                }
                .foregroundStyle(jade)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
