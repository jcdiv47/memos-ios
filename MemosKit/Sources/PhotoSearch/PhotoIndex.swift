import Foundation

/// Image embeddings by attachment name, from one model. Kept per account beside the local copy,
/// so signing out takes it with the memos.
public struct PhotoIndex: Sendable {
    public let variant: MobileCLIPVariant
    public private(set) var embeddings: [String: [Float]] = [:]

    public init(variant: MobileCLIPVariant) {
        self.variant = variant
    }

    public var count: Int { embeddings.count }

    public func contains(_ name: String) -> Bool { embeddings[name] != nil }

    public mutating func set(_ embedding: [Float], for name: String) {
        embeddings[name] = embedding
    }

    /// Forgets attachments that are no longer in any memo.
    public mutating func keep(only names: Set<String>) {
        embeddings = embeddings.filter { names.contains($0.key) }
    }

    public struct Match: Sendable, Equatable {
        public let name: String
        public let score: Float
    }

    /// The photos that match `query` best, best first. CLIP's scores only mean something next to
    /// each other, so a match has to clear a floor and stay near the best one: a search for
    /// “receipt” shows the receipts, not every photo ranked down to the last.
    public func matches(for query: [Float], among names: Set<String>? = nil, limit: Int = 30) -> [Match] {
        var scored: [Match] = []
        for (name, embedding) in embeddings where names?.contains(name) ?? true {
            scored.append(Match(name: name, score: Self.dot(query, embedding)))
        }
        guard let best = scored.max(by: { $0.score < $1.score })?.score, best >= Self.floor else { return [] }
        return scored
            .filter { $0.score >= Self.floor && $0.score >= best - Self.spread }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
            .prefix(limit)
            .map { $0 }
    }

    /// Text and a photo that have nothing to do with each other score about 0.07 to 0.13; a
    /// photo of what was described, from about 0.17 up.
    static let floor: Float = 0.17
    /// How far below the best match a photo can score and still be shown: “bird” finds every
    /// bird, and not the zebra next to them.
    static let spread: Float = 0.05

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for index in 0..<min(a.count, b.count) { sum += a[index] * b[index] }
        return sum
    }

    // MARK: Storage

    private struct Archive: Codable {
        var version = 1
        var variant: MobileCLIPVariant
        var embeddings: [String: Data]
    }

    /// The index at `url`, or nil when there's none or it came from another model.
    public static func read(_ url: URL, variant: MobileCLIPVariant) -> PhotoIndex? {
        guard let data = try? Data(contentsOf: url),
              let archive = try? PropertyListDecoder().decode(Archive.self, from: data),
              archive.version == 1, archive.variant == variant
        else { return nil }
        var index = PhotoIndex(variant: variant)
        for (name, bytes) in archive.embeddings {
            // Copied rather than reinterpreted: the bytes needn't be aligned for Float.
            index.embeddings[name] = [Float](unsafeUninitializedCapacity: bytes.count / MemoryLayout<Float>.size) { buffer, count in
                count = bytes.copyBytes(to: buffer) / MemoryLayout<Float>.size
            }
        }
        return index
    }

    public func write(to url: URL) throws {
        let archive = Archive(
            variant: variant,
            embeddings: embeddings.mapValues { vector in vector.withUnsafeBufferPointer { Data(buffer: $0) } }
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(archive).write(to: url, options: .atomic)
    }
}
