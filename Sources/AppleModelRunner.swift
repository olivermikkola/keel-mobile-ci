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
    /// With `tools`, the reply is held to a schema with one choice per tool
    /// plus "answer" (guided generation), and a chosen tool comes back as
    /// Keel's call text. The structured reply arrives whole, not streamed.
    static func generate(prompt: String, limit: Int, temperature: Double, tools: AppleToolPlan? = nil,
                         cancellation: InferenceCancellation,
                         onText: (String) -> Void) async throws -> InferenceTelemetry {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw LocalModelError.load }
        guard isAvailable else { throw LocalModelError.load }
        guard let parts = ApplePrompt.split(chatML: prompt) else { throw LocalModelError.context }
        let session = LanguageModelSession(instructions: tools == nil ? parts.instructions : AppleToolPlan.instructions(from: parts.instructions))
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: limit)
        let started = Date()
        var firstText: Date?
        var written = ""
        do {
            if let tools {
                let response = try await session.respond(to: parts.prompt, schema: try schema(for: tools), options: options)
                if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
                written = reply(from: response.content, plan: tools)
                firstText = Date()
                onText(written)
            } else {
            for try await snapshot in session.streamResponse(to: parts.prompt, options: options) {
                if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
                let text = snapshot.content
                // Snapshots hold the whole reply so far; pass on only what is new.
                guard text.count > written.count, text.hasPrefix(written) else { continue }
                if firstText == nil { firstText = Date() }
                onText(String(text.dropFirst(written.count)))
                written = text
            }
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
        let finished = Date(), firstAt = firstText ?? finished
        let total = finished.timeIntervalSince(started), writing = finished.timeIntervalSince(firstAt)
        // When the reply arrives in one piece (structured replies, short ones)
        // reading and writing cannot be told apart: report one rate over the
        // whole time instead of a writing rate over a few milliseconds.
        let split = writing >= 0.25 * total
        return InferenceTelemetry(prefillTokens: split ? ApplePrompt.estimatedTokens(parts.instructions + parts.prompt) : 0, reusedTokens: 0,
                                  prefillDuration: split ? total - writing : 0,
                                  decodedTokens: ApplePrompt.estimatedTokens(written),
                                  decodeDuration: split ? writing : total,
                                  footprintBytes: InferenceTelemetry.currentFootprintBytes())
        #else
        throw LocalModelError.load
        #endif
    }

    #if canImport(FoundationModels)
    /// One choice per tool, each naming itself in `tool`, plus the answer.
    @available(iOS 26.0, *)
    static func schema(for plan: AppleToolPlan) throws -> GenerationSchema {
        func named(_ choice: String) -> DynamicGenerationSchema.Property {
            .init(name: AppleToolPlan.choiceField, schema: DynamicGenerationSchema(name: "\(choice)_choice", anyOf: [choice]))
        }
        var choices = [DynamicGenerationSchema(name: AppleToolPlan.answer, description: "Reply to the user without a function.", properties: [
            named(AppleToolPlan.answer),
            .init(name: AppleToolPlan.answerText, description: "The reply to the user.", schema: DynamicGenerationSchema(type: String.self)),
        ])]
        for tool in plan.tools {
            var properties = [named(tool.name)]
            for parameter in tool.parameters {
                properties.append(.init(name: parameter.name,
                                        schema: parameter.isInteger ? DynamicGenerationSchema(type: Int.self) : DynamicGenerationSchema(type: String.self),
                                        isOptional: !parameter.required))
            }
            choices.append(DynamicGenerationSchema(name: tool.name, description: "Call \(tool.name).", properties: properties))
        }
        return try GenerationSchema(root: DynamicGenerationSchema(name: "step", anyOf: choices), dependencies: [])
    }

    /// The text the chat gets: Keel's call text for a chosen tool, else the answer.
    @available(iOS 26.0, *)
    static func reply(from content: GeneratedContent, plan: AppleToolPlan) -> String {
        let choice = (try? content.value(String.self, forProperty: AppleToolPlan.choiceField)) ?? AppleToolPlan.answer
        guard choice != AppleToolPlan.answer, let tool = plan.tools.first(where: { $0.name == choice }) else {
            return (try? content.value(String.self, forProperty: AppleToolPlan.answerText)) ?? ""
        }
        var arguments: [String: String] = [:]
        for parameter in tool.parameters {
            if parameter.isInteger, let value = try? content.value(Int.self, forProperty: parameter.name) { arguments[parameter.name] = String(value) }
            else if let value = try? content.value(String.self, forProperty: parameter.name) { arguments[parameter.name] = value }
        }
        // A required argument left out: hand back what was chosen so the strict
        // parser rejects it and the model is asked to correct the call.
        return plan.callText(choice: choice, arguments: arguments) ?? "<tool_call>\n<function=\(choice)>\n</function>\n</tool_call>"
    }
    #endif
}
