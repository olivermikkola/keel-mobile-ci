import Foundation

/// A spoken conversation, as a small state machine: listen, send what was
/// heard once the user pauses, wait for the reply, read it aloud, listen
/// again. The app feeds it what happens (words heard, time passing, the reply
/// finishing, speech ending) and does what it answers. No audio here.
public struct VoiceMode: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case off, listening, thinking, speaking }

    public enum Action: Equatable, Sendable {
        case startListening, stopListening
        /// Send this as the user's message.
        case send(String)
        /// Read this reply aloud.
        case speak(String)
        case stopSpeaking
        /// Stop whatever the model is writing.
        case stopReply
    }

    /// Silence after speech that counts as "finished talking".
    public static let pauseSeconds: TimeInterval = 1.8
    /// With nothing heard for this long, voice mode turns itself off.
    public static let idleSeconds: TimeInterval = 25

    public private(set) var phase = Phase.off
    /// What has been heard in the current turn.
    public private(set) var heard = ""
    private var changedAt: TimeInterval = 0

    public init() {}

    public var isOn: Bool { phase != .off }

    public mutating func start(now: TimeInterval) -> [Action] {
        guard phase == .off else { return [] }
        return listen(now: now)
    }

    /// The recognizer's running transcript for this turn.
    public mutating func hear(_ text: String, now: TimeInterval) -> [Action] {
        guard phase == .listening else { return [] }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned != heard { heard = cleaned; changedAt = now }
        return []
    }

    /// Called a few times a second while on.
    public mutating func tick(now: TimeInterval) -> [Action] {
        guard phase == .listening else { return [] }
        if heard.isEmpty {
            guard now - changedAt >= Self.idleSeconds else { return [] }
            phase = .off
            return [.stopListening]
        }
        guard now - changedAt >= Self.pauseSeconds else { return [] }
        return [.stopListening] + sendHeard()
    }

    /// The recognizer stopped by itself (its time limit, an interruption, an error).
    public mutating func listeningEnded() -> [Action] {
        guard phase == .listening else { return [] }
        if heard.isEmpty { phase = .off; return [] }
        return sendHeard()
    }

    /// The model finished. `reply` is what should be read aloud; nil or empty
    /// when there is nothing to say (an error, a stopped reply).
    public mutating func replyFinished(_ reply: String?, now: TimeInterval) -> [Action] {
        guard phase == .thinking else { return [] }
        guard let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .off
            return []
        }
        phase = .speaking
        return [.speak(reply)]
    }

    public mutating func speechFinished(now: TimeInterval) -> [Action] {
        guard phase == .speaking else { return [] }
        return listen(now: now)
    }

    /// The user tapped to talk over Keel: stop the voice (or the reply) and listen.
    public mutating func interrupt(now: TimeInterval) -> [Action] {
        switch phase {
        case .speaking: return [.stopSpeaking] + listen(now: now)
        case .thinking: return [.stopReply] + listen(now: now)
        case .listening, .off: return []
        }
    }

    public mutating func stop() -> [Action] {
        let was = phase
        phase = .off; heard = ""
        switch was {
        case .off: return []
        case .listening: return [.stopListening]
        case .thinking: return [.stopReply]
        case .speaking: return [.stopSpeaking]
        }
    }

    private mutating func listen(now: TimeInterval) -> [Action] {
        phase = .listening; heard = ""; changedAt = now
        return [.startListening]
    }

    private mutating func sendHeard() -> [Action] {
        let text = heard
        phase = .thinking; heard = ""
        return [.send(text)]
    }
}
