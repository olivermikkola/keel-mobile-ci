// For licensing see accompanying LICENSE.md file.
// Copyright (C) 2022 Apple Inc. All Rights Reserved.

import Foundation

/// A tokenizer based on byte pair encoding.
@available(iOS 16.2, macOS 13.1, *)
public struct BPETokenizer {
    /// A dictionary that maps pairs of tokens to the rank/order of the merge.
    let merges: [TokenPair : Int]

    /// A dictionary from of tokens to identifiers.
    let vocabulary: [String: Int]

    /// The token used for padding
    let padToken: String

    /// The start token.
    let startToken: String = "<|startoftext|>"

    /// The end token.
    let endToken: String = "<|endoftext|>"

    /// The unknown token.
    let unknownToken: String = "<|endoftext|>"

    var unknownTokenID: Int {
        vocabulary[unknownToken, default: 0]
    }

    /// Creates a tokenizer.
    ///
    /// - Parameters:
    ///   - merges: A dictionary that maps pairs of tokens to the rank/order of the merge.
    ///   - vocabulary: A dictionary from of tokens to identifiers.
    public init(merges: [TokenPair: Int], vocabulary: [String: Int], padToken: String = "<|endoftext|>") {
        self.merges = merges
        self.vocabulary = vocabulary
        self.padToken = padToken
    }

    /// Creates a tokenizer by loading merges and vocabulary from URLs.
    ///
    /// - Parameters:
    ///   - mergesURL: The URL of a text file containing merges.
    ///   - vocabularyURL: The URL of a JSON file containing the vocabulary.
    public init(mergesAt mergesURL: URL, vocabularyAt vocabularyURL: URL, padToken: String = "<|endoftext|>") throws {
        self.merges = try Self.readMerges(url: mergesURL)
        self.vocabulary = try Self.readVocabulary(url: vocabularyURL)
        self.padToken = padToken
    }

    /// Tokenizes an input string.
    ///
    /// - Parameters:
    ///   - input: A string.
    ///   - minCount: The minimum number of tokens to return.
    /// - Returns: An array of tokens and an array of token identifiers.
    public func tokenize(input: String, minCount: Int? = nil) -> (tokens: [String], tokenIDs: [Int]) {
        var tokens: [String] = []

        tokens.append(startToken)
        tokens.append(contentsOf: encode(input: input))
        tokens.append(endToken)

        // Pad if there was a min length specified
        if let minLen = minCount, minLen > tokens.count {
            tokens.append(contentsOf: repeatElement(padToken, count: minLen - tokens.count))
        }

        let ids = tokens.map({ vocabulary[$0, default: unknownTokenID] })
        return (tokens: tokens, tokenIDs: ids)
    }

    /// Returns the token identifier for a token.
    public func tokenID(for token: String) -> Int? {
        vocabulary[token]
    }

    /// Returns the token for a token identifier.
    public func token(id: Int) -> String? {
        vocabulary.first(where: { $0.value == id })?.key
    }

    /// Decodes a sequence of tokens into a fully formed string
    public func decode(tokens: [String]) -> String {
        String(tokens.joined())
            .replacingOccurrences(of: "</w>", with: " ")
            .replacingOccurrences(of: startToken, with: "")
            .replacingOccurrences(of: endToken, with: "")
    }

    /// Pre-tokenization regex matching OpenAI CLIP / OpenCLIP (`CLIPTokenizer`).
    /// Separates contractions, letter runs, digits, and punctuation so words
    /// followed by commas or periods still match their `</w>` vocabulary entries.
    private static let clipPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
        options: [.caseInsensitive]
    )

    /// Encode an input string to a sequence of tokens
    func encode(input: String) -> [String] {
        let collapsed = input.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        guard !collapsed.isEmpty else { return [] }
        if let regex = Self.clipPattern {
            let range = NSRange(collapsed.startIndex..<collapsed.endIndex, in: collapsed)
            let matches = regex.matches(in: collapsed, options: [], range: range)
            return matches.compactMap { Range($0.range, in: collapsed).map { collapsed[$0] } }
                .flatMap { encode(word: $0) }
        }
        let words = collapsed.split(separator: " ")
        return words.flatMap({ encode(word: $0) })
    }

    /// Encode a single word into a sequence of tokens
    func encode(word: Substring) -> [String] {
        var tokens = word.map { String($0) }
        if let last = tokens.indices.last {
            tokens[last] = tokens[last] + "</w>"
        }

        while true {
            let pairs = pairs(for: tokens)
            let canMerge = pairs.filter { merges[$0] != nil }

            if canMerge.isEmpty {
                break
            }

            // If multiple merges are found, use the one with the lowest rank
            let shouldMerge = canMerge.min { merges[$0]! < merges[$1]! }!
            tokens = update(tokens, merging: shouldMerge)
        }
        return tokens
    }

    /// Get  the set of adjacent pairs / bigrams from a sequence of tokens
    func pairs(for tokens: [String]) -> Set<TokenPair> {
        guard tokens.count > 1 else {
            return Set()
        }

        var pairs = Set<TokenPair>(minimumCapacity: tokens.count - 1)
        var prev = tokens.first!
        for current in tokens.dropFirst() {
            pairs.insert(TokenPair(prev, current))
            prev = current
        }
        return pairs
    }

    /// Update the sequence of tokens by greedily merging instance of a specific bigram
    func update(_ tokens: [String], merging bigram: TokenPair) -> [String] {
        guard tokens.count > 1 else {
            return []
        }

        var newTokens = [String]()
        newTokens.reserveCapacity(tokens.count - 1)

        var index = 0
        while index < tokens.count {
            let remainingTokens = tokens[index...]
            if let startMatchIndex = remainingTokens.firstIndex(of: bigram.first) {
                // Found a possible match, append everything before it
                newTokens.append(contentsOf: tokens[index..<startMatchIndex])

                if startMatchIndex < tokens.count - 1 && tokens[startMatchIndex + 1] == bigram.second {
                    // Full match, merge
                    newTokens.append(bigram.first + bigram.second)
                    index = startMatchIndex + 2
                } else {
                    // Only matched the first, no merge
                    newTokens.append(bigram.first)
                    index = startMatchIndex + 1
                }
            } else {
                // Didn't find any more matches, append the rest unmerged
                newTokens.append(contentsOf: remainingTokens)
                break
            }
        }
        return newTokens
    }
}

@available(iOS 16.2, macOS 13.1, *)
extension BPETokenizer {

    /// A hashable tuple of strings
    public struct TokenPair: Hashable {
        let first: String
        let second: String

        init(_ first: String, _ second: String) {
            self.first = first
            self.second = second
        }
    }
}
