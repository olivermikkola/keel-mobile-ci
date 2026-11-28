import SwiftUI
import UIKit
#if canImport(KeelHarness)
import KeelHarness
#endif

/// A spoken conversation, in place of the message field: Keel listens, sends
/// what it heard once you pause, reads its reply aloud and listens again.
/// Speech is recognised and spoken on this iPhone (`OfflineDictation`,
/// `ReplySpeech`); `VoiceMode` decides what happens when. Approvals still
/// appear on screen as usual.
struct VoiceBar: View {
    @EnvironmentObject private var models: ModelLibrary
    @EnvironmentObject private var chat: LocalChat
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var dictation = OfflineDictation()
    @StateObject private var speech = ReplySpeech()
    @State private var voice = VoiceMode()
    @State private var listening: Task<Void, Never>?
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3.weight(.medium)).foregroundStyle(KeelStyle.accent).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("voiceStatus")
            if voice.phase == .speaking {
                Button { handle(voice.interrupt(now: now)) } label: {
                    Image(systemName: "mic.fill").frame(width: 44, height: 44)
                        .foregroundStyle(KeelStyle.accent).background(KeelStyle.accent.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Talk now")
            }
            Button { handle(voice.stop()) } label: {
                Image(systemName: "xmark").fontWeight(.semibold).frame(width: 44, height: 44)
                    .foregroundStyle(KeelStyle.detail).background(KeelStyle.detail.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain).accessibilityLabel("End voice conversation").accessibilityIdentifier("endVoice")
        }
        .padding(12).background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(KeelStyle.accent.opacity(0.35)))
        .padding(.horizontal).padding(.top, 6).padding(.bottom, 12)
        .background(KeelStyle.background)
        .onAppear { handle(voice.start(now: now)); syncIdleTimer() }
        .onDisappear {
            perform(voice.stop())
            UIApplication.shared.isIdleTimerDisabled = chat.running && scenePhase == .active
        }
        .task {
            // The pause after speech is measured here, a few times a second.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { break }
                handle(voice.tick(now: now))
            }
        }
        .onChange(of: voice.phase) { _, _ in syncIdleTimer() }
        .onChange(of: dictation.text) { _, text in handle(voice.hear(text, now: now)) }
        .onChange(of: dictation.recording) { was, recording in
            guard was, !recording else { return }
            handle(voice.listeningEnded())
        }
        .onChange(of: dictation.error) { _, problem in
            // Dictation could not start (no permission, no offline language).
            guard let problem, voice.phase == .listening, !dictation.recording else { return }
            chat.error = problem
            handle(voice.stop())
        }
        .onChange(of: chat.running) { was, running in
            defer { syncIdleTimer() }
            guard was, !running else { return }
            let last = chat.messages.last
            let reply = chat.error == nil && last?.role == "assistant" && last?.isToolCall != true ? last?.text : nil
            handle(voice.replyFinished(reply, now: now))
        }
        .onChange(of: speech.speakingMessageID) { was, speaking in
            if was != nil, speaking == nil { handle(voice.speechFinished(now: now)) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { handle(voice.stop()) }
            syncIdleTimer()
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var symbol: String {
        switch voice.phase {
        case .listening, .off: return "waveform"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    private var title: String {
        switch voice.phase {
        case .listening, .off: return dictation.recording ? "Listening" : "Getting ready to listen…"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        }
    }

    private var detail: String {
        switch voice.phase {
        case .listening, .off: return voice.heard.isEmpty ? "Say something. Keel answers when you pause." : voice.heard
        case .thinking: return chat.phase.isEmpty ? "Working on your \(KeelDevice.name)…" : chat.phase
        case .speaking: return "Tap the microphone to talk over it."
        }
    }

    /// Keeps the screen awake during listening and spoken replies so iOS auto-lock
    /// does not interrupt an active voice conversation.
    private func syncIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = (voice.isOn || chat.running) && scenePhase == .active
    }

    /// Does what the state machine asked, then leaves if it turned itself off.
    private func handle(_ actions: [VoiceMode.Action]) {
        perform(actions)
        syncIdleTimer()
        if !voice.isOn { close() }
    }

    private func perform(_ actions: [VoiceMode.Action]) {
        for action in actions {
            switch action {
            case .startListening:
                listening?.cancel()
                listening = Task { await dictation.start() }
            case .stopListening:
                listening?.cancel(); listening = nil
                dictation.stop()
            case .send(let text):
                let sent = chat.send(text, attachments: [], model: models.current, path: models.path(models.current))
                if !chat.running {
                    let last = chat.messages.last
                    let reply = sent && chat.error == nil && last?.role == "assistant" && last?.isToolCall != true ? last?.text : nil
                    perform(voice.replyFinished(reply, now: now))
                }
            case .speak(let text):
                speech.speak(messageID: chat.messages.last?.id ?? UUID(), text: text)
                // Nothing in it can be read aloud (only code, say): listen again.
                if speech.speakingMessageID == nil { perform(voice.speechFinished(now: now)) }
            case .stopSpeaking:
                speech.stop()
            case .stopReply:
                chat.stop()
            }
        }
    }
}
