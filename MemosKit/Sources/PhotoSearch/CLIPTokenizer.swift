import Foundation

/// CLIP's byte-level BPE tokenizer, as OpenCLIP's `SimpleTokenizer` runs it: lowercased, split
/// into words, letters, single digits and runs of punctuation, then merged by rank. The text
/// encoder takes exactly ``contextLength`` tokens, start and end markers included, padded with 0.
public struct CLIPTokenizer: Sendable {
    public static let contextLength = 77

    private let encoder: [String: Int32]
    private let ranks: [Pair: Int]
    private let startToken: Int32
    private let endToken: Int32

    private struct Pair: Hashable {
        let first: String
        let second: String
    }

    /// `vocab.json` and `merges.txt`, as published with OpenCLIP checkpoints.
    public init(vocabulary: URL, merges: URL) throws {
        let encoder = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: vocabulary))
        let lines = try String(contentsOf: merges, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
        try self.init(encoder: encoder, merges: lines.filter { !$0.hasPrefix("#version") }.map(String.init))
    }

    init(encoder: [String: Int32], merges: [String]) throws {
        guard let start = encoder["<|startoftext|>"], let end = encoder["<|endoftext|>"] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var ranks: [Pair: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (rank, line) in merges.enumerated() {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            ranks[Pair(first: String(parts[0]), second: String(parts[1]))] = rank
        }
        self.encoder = encoder
        self.ranks = ranks
        self.startToken = start
        self.endToken = end
    }

    /// `text` as the text encoder's input. Long text is cut off, keeping the end marker.
    public func encode(_ text: String) -> [Int32] {
        var tokens: [Int32] = [startToken]
        let cleaned = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        for match in Self.pattern.matches(in: cleaned, range: range) {
            guard let wordRange = Range(match.range, in: cleaned) else { continue }
            let word = String(String.UnicodeScalarView(cleaned[wordRange].utf8.map { Self.byteEncoder[Int($0)] }))
            for piece in bpe(word) {
                if let id = encoder[piece] { tokens.append(id) }
            }
            if tokens.count >= Self.contextLength - 1 { break }
        }
        tokens = Array(tokens.prefix(Self.contextLength - 1))
        tokens.append(endToken)
        return tokens + Array(repeating: 0, count: Self.contextLength - tokens.count)
    }

    /// Merges the word's symbols, lowest rank first, until no ranked pair is left. The last
    /// symbol carries `</w>`, so word endings are told apart from word middles.
    private func bpe(_ word: String) -> [String] {
        var symbols = word.unicodeScalars.map { String($0) }
        guard let last = symbols.popLast() else { return [] }
        symbols.append(last + "</w>")
        while symbols.count > 1 {
            var best: (rank: Int, index: Int)?
            for index in 0..<(symbols.count - 1) {
                if let rank = ranks[Pair(first: symbols[index], second: symbols[index + 1])], rank < (best?.rank ?? .max) {
                    best = (rank, index)
                }
            }
            guard let best else { break }
            let first = symbols[best.index], second = symbols[best.index + 1]
            // Every occurrence of the pair merges in one pass, left to right, as CLIP does.
            var merged: [String] = []
            merged.reserveCapacity(symbols.count)
            var index = 0
            while index < symbols.count {
                if index < symbols.count - 1, symbols[index] == first, symbols[index + 1] == second {
                    merged.append(first + second)
                    index += 2
                } else {
                    merged.append(symbols[index])
                    index += 1
                }
            }
            symbols = merged
        }
        return symbols
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
        options: [.caseInsensitive]
    )

    /// GPT-2's byte-to-character table: printable bytes stand for themselves, the rest move to
    /// U+0100 and up, so every byte has a visible character the merges can name.
    private static let byteEncoder: [Unicode.Scalar] = {
        var printable = Array(33...126) + Array(161...172) + Array(174...255)
        var characters = printable
        var next = 0
        for byte in 0..<256 where !printable.contains(byte) {
            printable.append(byte)
            characters.append(256 + next)
            next += 1
        }
        var table = [Unicode.Scalar](repeating: "\0", count: 256)
        for (byte, character) in zip(printable, characters) {
            table[byte] = Unicode.Scalar(UInt32(character))!
        }
        return table
    }()
}
