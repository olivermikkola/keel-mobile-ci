import Foundation

/// A model the user brought as a GGUF file. It is pinned at import by size and
/// SHA-256, like the catalog's downloads, and planned from its header: which
/// prompt format it speaks and a context that fits this device's memory.
struct ImportedModel: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    let bytes: Int64
    let sha256: String
    let family: ModelFamily
    let contextSize: UInt32
    let architecture: String
    let layerCount: Int
    let attentionLayerCount: Int
    let kvHeadCount: Int
    let keyLength: Int
    let valueLength: Int
    let ssmInnerSize: Int
    let ssmStateSize: Int
    let ssmConvKernel: Int

    var fileName: String { id + ".gguf" }

    /// Context asked of the memory gate; the gate steps it down when it does not fit.
    static let targetContext: UInt32 = 8_192
    /// How many imported models the app keeps track of.
    static let limit = 12
    /// Stands in for a Hugging Face repository on the app's model entry.
    static let source = "imported"


    enum Problem: LocalizedError, Equatable {
        case notGGUF(String)
        case chatFormat(String)
        case memory(String)

        var errorDescription: String? {
            switch self {
            case .notGGUF(let detail): return "This file is not a model Keel can read. \(detail)"
            case .chatFormat(let detail): return detail
            case .memory(let detail): return detail
            }
        }
    }

    /// Which prompt format the model speaks and how much context fits, or why it cannot run here.
    static func plan(header: GGUFHeader, bytes: Int64, physicalMemoryBytes: UInt64) throws -> (family: ModelFamily, contextSize: UInt32) {
        let family: ModelFamily
        switch header.chatTemplateKind {
        case .lfm3: family = .lfm3
        case .miniCPM5: family = .miniCPM5
        case .chatML:
            // The header's template is often past the first 256 KB, so ChatML
            // is also the fallback guess. Trust it only for Qwen-family models,
            // which use it; anything else would get a prompt it was not trained on.
            guard header.architecture.lowercased().hasPrefix("qwen") else {
                throw Problem.chatFormat("Keel cannot tell which chat format this \(header.architecture) model uses, so it cannot prompt it correctly. Qwen, LFM and MiniCPM models are supported.")
            }
            family = .bonsai
        case .gemma, .llama3:
            throw Problem.chatFormat("This model uses the \(header.chatTemplateKind == .gemma ? "Gemma" : "Llama 3") chat format, which Keel does not support yet. Qwen, LFM and MiniCPM models are supported.")
        }
        let verdict = DeviceMemoryGate.evaluate(header: header, weightBytes: UInt64(max(0, bytes)), targetContext: targetContext,
                                                physicalMemoryBytes: physicalMemoryBytes)
        switch verdict {
        case .fits(let context, _, _), .reducedContext(let context, _, _):
            return (family, context)
        case .contextBelowMinimum(let context, let minimum):
            throw Problem.memory("This model supports \(context) tokens of context; Keel needs at least \(minimum) for tasks.")
        case .unsupportedArchitecture(let name):
            throw Problem.memory("Keel cannot estimate memory for the \(name) architecture, so it will not load it.")
        case .tooLarge(let required, let budget):
            throw Problem.memory("This model needs about \(gigabytes(required)) of memory even with a short conversation; this device can give an app about \(gigabytes(budget)).")
        }
    }

    init(id: String = ImportedModel.newID(), name: String, bytes: Int64, sha256: String, header: GGUFHeader,
         family: ModelFamily, contextSize: UInt32) {
        self.id = id
        self.name = Self.cleanName(name)
        self.bytes = bytes
        self.sha256 = sha256
        self.family = family
        self.contextSize = contextSize
        architecture = header.architecture
        layerCount = header.layerCount
        attentionLayerCount = header.attentionLayerCount
        kvHeadCount = header.kvHeadCount
        keyLength = header.keyLength
        valueLength = header.valueLength
        ssmInnerSize = header.ssmInnerSize
        ssmStateSize = header.ssmStateSize
        ssmConvKernel = header.ssmConvKernel
    }

    static func newID() -> String {
        "custom-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The file name without `.gguf`, on one line, at most 60 characters.
    static func cleanName(_ name: String) -> String {
        var text = name.hasSuffix(".gguf") ? String(name.dropLast(5)) : name
        text = text.filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "Imported model" : String(text.prefix(60))
    }

    /// A saved record is used only if it is one this app could have written.
    var isValid: Bool {
        id.range(of: "^custom-[0-9a-f]{32}$", options: .regularExpression) != nil
            && !name.isEmpty && name.count <= 60
            && sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            && bytes > 0
            && contextSize >= DeviceMemoryGate.minimumAgentContext && contextSize <= 32_768
            && name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            && [layerCount, attentionLayerCount, kvHeadCount, keyLength, valueLength,
                ssmInnerSize, ssmStateSize, ssmConvKernel].allSatisfy { $0 >= 0 && $0 <= GGUFHeader.maxEmbeddingLength }
            && attentionLayerCount <= layerCount && (1...GGUFHeader.maxLayerCount).contains(layerCount)
    }

    /// Reads the saved list, keeping only valid, distinct records.
    static func load(_ data: Data) -> [ImportedModel] {
        guard let records = try? JSONDecoder().decode([ImportedModel].self, from: data) else { return [] }
        var seen = Set<String>()
        return Array(records.filter { $0.isValid && seen.insert($0.id).inserted }.prefix(limit))
    }

    private static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}
