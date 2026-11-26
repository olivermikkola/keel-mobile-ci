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
        enum Kind: Equatable, Sendable {
            case guardrailViolation
            case assetsUnavailable
            case other
        }
        let kind: Kind
        let detail: String
        init(kind: Kind = .other, detail: String) {
            self.kind = kind
            self.detail = detail
        }
        var errorDescription: String? { "Apple's on-device model could not answer. \(detail)" }
    }

    /// Why the model cannot be used here, or nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This device does not support Apple Intelligence."
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
    /// With `tools`, each is registered with Apple's own tool calling. The
    /// first call the model makes is taken (Apple's session stops there) and
    /// handed back as Keel's call text; Keel's approvals and tools run it.
    static func generate(prompt: String, limit: Int, temperature: Double, tools: AppleToolPlan? = nil,
                         cancellation: InferenceCancellation,
                         onText: (String) -> Void) async throws -> InferenceTelemetry {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw LocalModelError.load }
        guard isAvailable else { throw LocalModelError.load }
        guard let parts = ApplePrompt.split(chatML: prompt) else { throw LocalModelError.context }
        let taken = TakenCall()
        let session: LanguageModelSession
        if let tools {
            session = LanguageModelSession(tools: try nativeTools(for: tools, taking: taken),
                                           instructions: AppleToolPlan.instructions(from: parts.instructions))
        } else {
            session = LanguageModelSession(instructions: parts.instructions)
        }
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: limit)
        let started = Date()
        var firstText: Date?
        var written = ""
        do {
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
            } catch {
                // A tool call stops Apple's session (see `NativeTool`): hand
                // the call back as Keel's text instead of an error.
                guard let tools, let call = taken.callText(plan: tools) else { throw error }
                if firstText == nil { firstText = Date() }
                let text = (written.isEmpty ? "" : "\n") + call
                onText(text)
                written += text
            }
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw LocalModelError.tooLong
            case .guardrailViolation: throw Failure(kind: .guardrailViolation, detail: "Apple's safety filter stopped this reply.")
            case .assetsUnavailable: throw Failure(kind: .assetsUnavailable, detail: "Its model files are not on this device yet. Try again later.")
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
        // When the reply arrives in one piece (a tool call, a short reply)
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
    /// The first tool call the model made, kept so it can be handed to Keel.
    @available(iOS 26.0, *)
    final class TakenCall: @unchecked Sendable {
        private let lock = NSLock()
        private var name: String?
        private var arguments: GeneratedContent?
        /// Thrown from the tool to stop Apple's session before it runs anything.
        struct Stop: Error {}

        func take(_ name: String, _ arguments: GeneratedContent) {
            lock.withLock { if self.name == nil { self.name = name; self.arguments = arguments } }
        }

        func callText(plan: AppleToolPlan) -> String? {
            let (recorded, content) = lock.withLock { (name, arguments) }
            guard let name = recorded, let tool = plan.tools.first(where: { $0.name == name }) else { return nil }
            var values: [String: String] = [:]
            for parameter in tool.parameters {
                switch parameter.valueType {
                case .integer:
                    if let value = try? content?.value(Int.self, forProperty: parameter.name) { values[parameter.name] = String(value) }
                case .number:
                    if let value = try? content?.value(Double.self, forProperty: parameter.name) { values[parameter.name] = String(value) }
                case .boolean:
                    if let value = try? content?.value(Bool.self, forProperty: parameter.name) { values[parameter.name] = value ? "true" : "false" }
                case .string:
                    if let value = try? content?.value(String.self, forProperty: parameter.name) { values[parameter.name] = value }
                }
            }
            // A required argument left out: hand back the bare call so the
            // strict parser rejects it and the model is asked to correct it.
            return plan.callText(choice: name, arguments: values) ?? "<tool_call>\n<function=\(name)>\n</function>\n</tool_call>"
        }
    }

    /// A Keel tool as Apple's framework sees it. It never runs anything: the
    /// call is recorded and the session stopped, so Keel's own approvals apply.
    @available(iOS 26.0, *)
    struct NativeTool: Tool {
        let name: String
        let description: String
        let parameters: GenerationSchema
        let taken: TakenCall

        func call(arguments: GeneratedContent) async throws -> String {
            taken.take(name, arguments)
            throw TakenCall.Stop()
        }
    }

    @available(iOS 26.0, *)
    static func nativeTools(for plan: AppleToolPlan, taking taken: TakenCall) throws -> [any Tool] {
        try plan.tools.map { tool in
            let properties = tool.parameters.map { parameter -> DynamicGenerationSchema.Property in
                let schema: DynamicGenerationSchema
                switch parameter.valueType {
                case .integer: schema = DynamicGenerationSchema(type: Int.self)
                case .number: schema = DynamicGenerationSchema(type: Double.self)
                case .boolean: schema = DynamicGenerationSchema(type: Bool.self)
                case .string: schema = DynamicGenerationSchema(type: String.self)
                }
                return DynamicGenerationSchema.Property(
                    name: parameter.name,
                    description: parameter.description.isEmpty ? nil : parameter.description,
                    schema: schema,
                    isOptional: !parameter.required
                )
            }
            let schema = try GenerationSchema(root: DynamicGenerationSchema(name: tool.name, properties: properties), dependencies: [])
            return NativeTool(name: tool.name, description: tool.description, parameters: schema, taken: taken)
        }
    }
    #endif
}
