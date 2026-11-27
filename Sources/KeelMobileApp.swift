import SwiftUI

@main
@MainActor
struct KeelMobileApp: App {
    @UIApplicationDelegateAdaptor(NotificationAppDelegate.self) private var appDelegate
    @StateObject private var notifications = TaskNotifications.shared
    @StateObject private var workspace = Workspace()
    @StateObject private var models = ModelLibrary()
    @StateObject private var imageModels = ImageModelStore()
    @StateObject private var narration = NarrationVoiceStore()
    @StateObject private var decide = DecideSession()
    @StateObject private var hardware = HardwareRecommendationStore()
    @StateObject private var chat: LocalChat

    init() {
        #if DEBUG && targetEnvironment(simulator)
        _chat = StateObject(wrappedValue: LocalChat(transcript: ChatAppearanceUITestFixture.transcript()))
        if ProcessInfo.processInfo.arguments.contains("--first-run-without-system-model") {
            let xr = HardwareProfile.detectCurrent(machineIdentifier: "iPhone11,8", physicalMemoryBytes: 3_000_000_000)
            _hardware = StateObject(wrappedValue: HardwareRecommendationStore(currentDevice: xr))
            _models = StateObject(wrappedValue: ModelLibrary(includeSystemModel: false))
        }
        #else
        _chat = StateObject(wrappedValue: LocalChat())
        #endif
        KeelStyle.applyBarAppearance()
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
            #if DEBUG && targetEnvironment(simulator)
            if ShortVideoDraftFixture.isOn {
                ShortVideoDraftFixtureView().preferredColorScheme(previewAppearance).tint(KeelStyle.accent)
            } else {
                root
            }
            #else
            root
            #endif
        }
    }

    private var root: some View {
        Group {
            ContentView().environmentObject(workspace).environmentObject(models)
                .environmentObject(imageModels).environmentObject(decide).environmentObject(narration)
                .environmentObject(hardware)
                .environmentObject(chat).environmentObject(notifications).preferredColorScheme(previewAppearance)
                .tint(KeelStyle.accent)
                // Handles Shortcuts return callbacks, keelmobile://ask|open deep links,
                // and files shared via "Open in Keel Mobile".
                .onOpenURL { chat.receiveIncomingURL($0) }
        }
    }
}
