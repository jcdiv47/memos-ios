import Foundation
import ImageIO
import Testing
@testable import PhotoSearch

/// A folder laid out as an install leaves it (`image.mlmodelc`, `text.mlmodelc`, `vocab.json`,
/// `merges.txt`): `MOBILECLIP_TEST_MODEL=/path/to/s0 swift test`.
private let modelFolder = ProcessInfo.processInfo.environment["MOBILECLIP_TEST_MODEL"].map { URL(fileURLWithPath: $0) }

/// `MOBILECLIP_TEST_DOWNLOAD=1` downloads S0 from Hugging Face, about 105 MB.
private let testsDownload = ProcessInfo.processInfo.environment["MOBILECLIP_TEST_DOWNLOAD"] == "1"

@Suite(.enabled(if: modelFolder != nil, "Set MOBILECLIP_TEST_MODEL to a folder with the tokenizer and compiled S0 model"))
struct `CLIP tokenizer` {
    let tokenizer = try! CLIPTokenizer(
        vocabulary: modelFolder!.appending(path: "vocab.json"),
        merges: modelFolder!.appending(path: "merges.txt")
    )

    /// Expected IDs from Hugging Face's `tokenizers` with the published `tokenizer.json`.
    @Test(arguments: [
        ("a photo of a dog", [49406, 320, 1125, 539, 320, 1929, 49407]),
        ("Receipts from the café, 2024!", [49406, 41181, 633, 518, 15304, 267, 273, 271, 273, 275, 256, 49407]),
        ("it's my DOG's birthday", [49406, 585, 568, 607, 1929, 568, 1166, 49407]),
        ("  whitespace\n\tand   tabs ", [49406, 4699, 2138, 537, 29163, 49407]),
        ("猫", [49406, 163, 234, 360, 49407]),
        ("electroencephalography", [49406, 11648, 6495, 745, 3435, 4897, 49407]),
    ])
    func `matches the reference tokenizer`(text: String, expected: [Int32]) {
        let tokens = tokenizer.encode(text)
        #expect(tokens.count == CLIPTokenizer.contextLength)
        #expect(Array(tokens.prefix(expected.count)) == expected)
        #expect(tokens.dropFirst(expected.count).allSatisfy { $0 == 0 })
    }

    @Test func `long text is cut off and still ends with the end marker`() {
        let tokens = tokenizer.encode(String(repeating: "dog ", count: 200))
        #expect(tokens.count == CLIPTokenizer.contextLength)
        #expect(tokens.first == 49406)
        #expect(tokens.last == 49407)
        #expect(tokens.dropFirst().dropLast().allSatisfy { $0 == 1929 })
    }
}

@Suite(.enabled(if: modelFolder != nil, "Set MOBILECLIP_TEST_MODEL to a folder with the tokenizer and compiled S0 model"))
struct `MobileCLIP on real photos` {
    static let animals = ["Parrot", "Owl", "Eagle", "Zebra", "Penguin"]

    func picture(_ name: String) throws -> CGImage {
        let url = URL(fileURLWithPath: "/Library/User Pictures/Animals/\(name).heic")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CocoaError(.fileReadNoSuchFile) }
        return image
    }

    @Test func `each animal is found by its name`() async throws {
        let model = try await MobileCLIP(variant: .s0, folder: modelFolder!)
        var index = PhotoIndex(variant: .s0)
        for animal in Self.animals {
            let embedding = try await model.embed(picture(animal))
            #expect(embedding.count == 512)
            #expect(abs(PhotoIndex.dot(embedding, embedding) - 1) < 0.001)
            index.set(embedding, for: animal)
        }
        for animal in Self.animals {
            let query = try await model.embed("a \(animal.lowercased())")
            let matches = index.matches(for: query)
            #expect(matches.first?.name == animal, "\(animal): \(matches)")
        }
        // Something none of them are.
        let unrelated = try await model.embed("a spreadsheet of quarterly tax figures")
        #expect(index.matches(for: unrelated).count < Self.animals.count)
    }
}

@Suite(.enabled(if: testsDownload, "Set MOBILECLIP_TEST_DOWNLOAD=1 to download S0"))
struct `Installing MobileCLIP` {
    @Test func `S0 downloads, checks out, compiles and loads`() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mobileclip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = MobileCLIPStorage(directory: directory)
        #expect(storage.installed == nil)
        let last = LastValue()
        try await storage.install(.s0) { last.set($0) }
        #expect(storage.installed == .s0)
        #expect(last.value == 1)
        let model = try #require(try await storage.load())
        #expect(try await model.embed("a dog").count == 512)
        try storage.remove()
        #expect(storage.installed == nil)
    }

    final class LastValue: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Double = 0
        var value: Double { lock.withLock { stored } }
        func set(_ value: Double) { lock.withLock { stored = value } }
    }
}

struct `Photo index` {
    func vector(_ values: Float...) -> [Float] {
        let length = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return values.map { $0 / length }
    }

    @Test func `shows only what clears the floor and stays near the best`() {
        var index = PhotoIndex(variant: .s0)
        index.set(vector(1, 0, 0), for: "receipt")
        index.set(vector(0.95, 0.31, 0), for: "invoice")
        index.set(vector(0, 1, 0), for: "dog")
        let query = vector(0.3, 0, 0.95)
        let matches = index.matches(for: query)
        #expect(matches.map(\.name) == ["receipt", "invoice"])
        #expect(index.matches(for: query, among: ["invoice", "dog"]).map(\.name) == ["invoice"])
        #expect(index.matches(for: vector(0, 0, 1)).isEmpty)
    }

    @Test func `reads back what it wrote, for the same model only`() throws {
        var index = PhotoIndex(variant: .s2)
        index.set(vector(1, 2, 3), for: "attachments/a")
        index.set(vector(3, 2, 1), for: "attachments/b")
        let url = FileManager.default.temporaryDirectory.appending(path: "photo-index-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try index.write(to: url)
        let read = try #require(PhotoIndex.read(url, variant: .s2))
        #expect(read.embeddings == index.embeddings)
        #expect(PhotoIndex.read(url, variant: .s0) == nil)

        var kept = read
        kept.keep(only: ["attachments/b"])
        #expect(Array(kept.embeddings.keys) == ["attachments/b"])
    }
}
