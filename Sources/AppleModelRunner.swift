import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Apple's built-in on-device model (iOS 26 and later, with Apple Intelligence
/// on). Nothing to download; Apple runs it. Keel gives it the chat's system
/// prompt as instructions and the conversation as one prompt (`ApplePrompt`),
/// and reads tool calls from its text as for any other model. Apple's
/// framework has its own sampler and context limit (about 4K tokens) and
/// reports no token counts, so the speed line uses estimates.
enum AppleModelRunner {
    /// Apple's framework failed for a reason of its own (a safety refusal,
    /// missing model files). Says so in plain words instead of an error code.
    struct Failure: LocalizedError, Equatable {
        let detail: String
        var errorDescription: String? { "Apple's on-device model could not answer. \(detail)" }
    }

    /// Why the model cannot be used here, or nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This iPhone does not support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings to use Apple's on-device model."
            case .unavailable(.modelNotReady): return "Apple's on-device model is still downloading. Try again later."
            case .unavailable: return "Apple's on-device model is not available right now."
            }
        }
        return "Apple's on-device model needs iOS 26 or later."
        #else
        return "This build has no Apple on-device model support."
        #endif
    }

    static var isAvailable: Bool { unavailableReason == nil }

    /// Writes the next reply. `onText` receives each new piece of text in order.
    static func generate(prompt: String, limit: Int, temperature: Double, cancellation: InferenceCancellation,
                         onText: (String) -> Void) async throws -> InferenceTelemetry {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw LocalModelError.load }
        guard isAvailable else { throw LocalModelError.load }
        guard let parts = ApplePrompt.split(chatML: prompt) else { throw LocalModelError.context }
        let session = LanguageModelSession(instructions: parts.instructions)
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: limit)
        let started = Date()
        var firstText: Date?
        var written = ""
        do {
            for try await snapshot in session.streamResponse(to: parts.prompt, options: options) {
                if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
                let text = snapshot.content
                // Snapshots hold the whole reply so far; pass on only what is new.
                guard text.count > written.count, text.hasPrefix(written) else { continue }
                if firstText == nil { firstText = Date() }
                onText(String(text.dropFirst(written.count)))
                written = text
            }
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw LocalModelError.tooLong
            case .guardrailViolation: throw Failure(detail: "Apple's safety filter stopped this reply.")
            case .assetsUnavailable: throw Failure(detail: "Its model files are not on this device yet. Try again later.")
            default: throw Failure(detail: error.localizedDescription)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The framework can also surface its errors bridged as NSError
            // (domain FoundationModels…GenerationError), which the enum above
            // does not match. Anything from it is Apple's failure, said plainly.
            let detail = (error as NSError).localizedFailureReason ?? "Apple's framework reported an error (\((error as NSError).domain) \((error as NSError).code))."
            throw Failure(detail: detail)
        }
        let firstAt = firstText ?? Date()
        return InferenceTelemetry(prefillTokens: ApplePrompt.estimatedTokens(parts.instructions + parts.prompt), reusedTokens: 0,
                                  prefillDuration: firstAt.timeIntervalSince(started),
                                  decodedTokens: ApplePrompt.estimatedTokens(written),
                                  decodeDuration: Date().timeIntervalSince(firstAt),
                                  footprintBytes: InferenceTelemetry.currentFootprintBytes())
        #else
        throw LocalModelError.load
        #endif
    }
}
