import SwiftUI

@main
@MainActor
struct KeelMobileApp: App {
    @StateObject private var workspace = Workspace()
    @StateObject private var models = ModelLibrary()
    @StateObject private var chat: LocalChat

    init() {
        #if DEBUG && targetEnvironment(simulator)
        _chat = StateObject(wrappedValue: LocalChat(transcript: ChatAppearanceUITestFixture.transcript()))
        #else
        _chat = StateObject(wrappedValue: LocalChat())
        #endif
    }

    private var previewAppearance: ColorScheme? {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--appearance-dark") { return .dark }
        if ProcessInfo.processInfo.arguments.contains("--appearance-light") { return .light }
        #endif
        return nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(workspace).environmentObject(models)
                .environmentObject(chat).preferredColorScheme(previewAppearance)
                .tint(KeelStyle.accent)
        }
    }
}
