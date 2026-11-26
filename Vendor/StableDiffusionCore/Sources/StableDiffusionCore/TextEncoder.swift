// For licensing see accompanying LICENSE.md file.
// Copyright (C) 2022 Apple Inc. All Rights Reserved.

import Foundation
import CoreML

@available(iOS 16.2, macOS 13.1, *)
public protocol TextEncoderModel: ResourceManaging {

    func encode(_ text: String) throws -> MLShapedArray<Float32>
}

///  A model for encoding text
@available(iOS 16.2, macOS 13.1, *)
public struct TextEncoder: TextEncoderModel {

    /// Text tokenizer
    var tokenizer: BPETokenizer

    /// Embedding model
    var model: ManagedMLModel

    /// Creates text encoder which embeds a tokenized string
    ///
    /// - Parameters:
    ///   - tokenizer: Tokenizer for input text
    ///   - url: Location of compiled text encoding  Core ML model
    ///   - configuration: configuration to be used when the model is loaded
    /// - Returns: A text encoder that will lazily load its required resources when needed or requested
    public init(tokenizer: BPETokenizer,
                modelAt url: URL,
                configuration: MLModelConfiguration) {
        self.tokenizer = tokenizer
        self.model = ManagedMLModel(modelAt: url, configuration: configuration)
    }

    /// Ensure the model has been loaded into memory
    public func loadResources() throws {
        try model.loadResources()
    }

    /// Unload the underlying model to free up memory
    public func unloadResources() {
       model.unloadResources()
    }

    /// Encode input text/string
    ///
    ///  - Parameters:
    ///     - text: Input text to be tokenized and then embedded
    ///  - Returns: Embedding representing the input text
    public func encode(_ text: String) throws -> MLShapedArray<Float32> {

        // Get models expected input length
        let shape = try inputShape()
        guard let inputLength = shape.last else {
            throw NSError(domain: "StableDiffusionCore.TextEncoder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid TextEncoder input shape."])
        }

        // Tokenize, padding to the expected length
        var (tokens, ids) = tokenizer.tokenize(input: text, minCount: inputLength)

        // Truncate if necessary
        if ids.count > inputLength {
            tokens = tokens.dropLast(tokens.count - inputLength)
            ids = ids.dropLast(ids.count - inputLength)
            let truncated = tokenizer.decode(tokens: tokens)
            print("Needed to truncate input '\(text)' to '\(truncated)'")
        }

        // Use the model to generate the embedding
        return try encode(ids: ids)
    }

    /// Prediction queue
    let queue = DispatchQueue(label: "textencoder.predict")

    func encode(ids: [Int]) throws -> MLShapedArray<Float32> {
        let description = try inputDescription()
        let inputName = description.name
        let shape = try inputShape()

        let floatIds = ids.map { Float32($0) }
        let inputArray = MLShapedArray<Float32>(scalars: floatIds, shape: shape)
        let inputFeatures = try MLDictionaryFeatureProvider(
            dictionary: [inputName: MLMultiArray(inputArray)])

        let result = try model.perform { model in
            try model.prediction(from: inputFeatures)
        }

        guard let embeddingFeature = result.featureValue(for: "last_hidden_state"),
              let multiArray = embeddingFeature.multiArrayValue else {
            throw NSError(domain: "StableDiffusionCore.TextEncoder", code: 2, userInfo: [NSLocalizedDescriptionKey: "TextEncoder did not return last_hidden_state."])
        }
        return MLShapedArray<Float32>(converting: multiArray)
    }

    func inputDescription() throws -> MLFeatureDescription {
        try model.perform { model in
            guard let first = model.modelDescription.inputDescriptionsByName.first?.value else {
                throw NSError(domain: "StableDiffusionCore.TextEncoder", code: 3, userInfo: [NSLocalizedDescriptionKey: "TextEncoder has no input description."])
            }
            return first
        }
    }

    func inputShape() throws -> [Int] {
        guard let constraint = try inputDescription().multiArrayConstraint else {
            throw NSError(domain: "StableDiffusionCore.TextEncoder", code: 4, userInfo: [NSLocalizedDescriptionKey: "TextEncoder input lacks shape constraint."])
        }
        return constraint.shape.map { $0.intValue }
    }

}
