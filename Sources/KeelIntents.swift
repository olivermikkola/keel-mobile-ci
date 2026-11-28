import AppIntents
import SwiftUI

/// What Siri, Spotlight, the Shortcuts app, the Action button or a Control
/// Center control asked Keel to do. Each intent opens Keel: the model runs only
/// in the foreground, so nothing is answered from inside Siri.
enum IntentRequest: Equatable {
    case ask(String)
    case newChat
}

/// Holds the last request until the chat can take it (models listed, no reply
/// running), the same way a tapped scheduled-task notification waits.
@MainActor
final class IntentInbox: ObservableObject {
    static let shared = IntentInbox()
    @Published var pending: IntentRequest?
    /// Same bound as a scheduled task's prompt.
    static let maxQuestionBytes = 16_384

    func receive(_ request: IntentRequest) { pending = request }

    /// Developer check on a USB-connected phone, where nobody taps the screen:
    /// `pymobiledevice3 developer dvt launch "com.olivermikkola.keelmobile -KeelSelfTestPrompt 'Say hi'"`
    /// asks once, through the same path as Siri's Ask Keel, with the chosen model.
    /// Only a paired developer tool can pass launch arguments, and they are not
    /// saved, so a normal launch never sees one.
    private var selfTestTaken = false
    func takeSelfTestPrompt(_ defaults: UserDefaults = .standard) {
        guard !selfTestTaken else { return }
        selfTestTaken = true
        guard let prompt = defaults.string(forKey: "KeelSelfTestPrompt")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty, prompt.utf8.count <= Self.maxQuestionBytes else { return }
        pending = .ask(prompt)
    }
}

struct AskKeelIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Keel"
    // App Store Connect rejects intent text naming Apple products (ITMS-90626:
    // "cannot contain 'iphone'"), so say "your device".
    static let description = IntentDescription("Opens a new Keel chat with your question. Keel answers on your device.")
    static let openAppWhenRun = true

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask Keel?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= IntentInbox.maxQuestionBytes else {
            throw $question.needsValueError("What do you want to ask Keel? Keep it under 16,000 characters.")
        }
        IntentInbox.shared.receive(.ask(text))
        return .result()
    }
}

struct NewKeelChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New Keel Chat"
    static let description = IntentDescription("Opens Keel on an empty chat.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentInbox.shared.receive(.newChat)
        return .result()
    }
}

/// Phrases Siri knows without setup, and the actions Spotlight, the Action
/// button and the Shortcuts app show for Keel.
struct KeelShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskKeelIntent(),
                    phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
                    shortTitle: "Ask Keel", systemImageName: "bubble.left")
        AppShortcut(intent: NewKeelChatIntent(),
                    phrases: ["New chat in \(.applicationName)", "Start a \(.applicationName) chat"],
                    shortTitle: "New Chat", systemImageName: "square.and.pencil")
    }
}
