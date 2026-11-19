import CoreGraphics
import CoreML
import CryptoKit
import Foundation
import Vision

/// The MobileCLIP sizes Apple publishes as Core ML, each an image encoder and a text encoder
/// that map into the same 512-dimensional space.
public enum MobileCLIPVariant: String, CaseIterable, Codable, Sendable, Identifiable {
    case s0
    case s2

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .s0: "MobileCLIP-S0"
        case .s2: "MobileCLIP-S2"
        }
    }

    /// What the download weighs, for the size shown before it starts.
    public var downloadSize: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Every file, pinned to one revision of Apple's repositories and checked by SHA-256, so
    /// what runs is exactly what was published.
    var files: [RemoteFile] {
        let manifests: (image: String, text: String)
        let models: (image: (Int64, String), text: (Int64, String))
        let weights: (image: (Int64, String), text: (Int64, String))
        switch self {
        case .s0:
            manifests = ("fe07dde983dae92c1799132816ce55f9ff8487f2681b530abf7222025aa27fa4",
                         "a7cb0864a627468a953afd107262097ad74a0fcf82e49df7e00b9c86385bb7db")
            models = ((153_260, "2c1afa132c41c6535817cc67894bd7484bc2cbd084ed5e2f12b24f611af17591"),
                      (57_953, "81eba836ff4dbc8ae021d70006288b533ba7eed3c2973d245b0d5ea047305bfd"))
            weights = ((22_717_696, "87d8f63997bbd2f38ba7defeaaa2c571928bdece56aa9629542198b3ce906ed6"),
                       (84_871_616, "34723e51445b2630106e94e1fdbebed80e7676b404fb839f4eb9bec97bdcad68"))
        case .s2:
            manifests = ("6a1a3f93b8dca6c237dbb5dc7b19bb3c987042d14860288304986c099d8796b6",
                         "ea6a189d82fee2ee36eadb99022cda66a7f6b50a4bf9cc1d9541c7ea3b4242a0")
            models = ((299_056, "2aeb3359f6cde65e9f9248ec2a742e9939bd4bbf48c2f55fcd255b4504d96a1b"),
                      (128_127, "b8651b6d030bae419a9548b41c8fae11f96b59cfa21b6e532a4c4434522b4b80"))
            weights = ((71_397_632, "6cbc7fb06b6072c1cae9c4496d67e0e6217adbf726dfeb82e44d4efe87c34c00"),
                       (126_866_880, "8e8d5454f104b6cbb58d98bf11e038ff1f1943599efea111260a832f094cd0ce"))
        }
        func package(_ part: String, manifest: String, model: (Int64, String), weights: (Int64, String)) -> [RemoteFile] {
            let package = "mobileclip_\(rawValue)_\(part).mlpackage"
            return [
                RemoteFile(repository: .coreML, path: "\(package)/Manifest.json", local: "\(part).mlpackage/Manifest.json", size: 617, sha256: manifest),
                RemoteFile(repository: .coreML, path: "\(package)/Data/com.apple.CoreML/model.mlmodel", local: "\(part).mlpackage/Data/com.apple.CoreML/model.mlmodel", size: model.0, sha256: model.1),
                RemoteFile(repository: .coreML, path: "\(package)/Data/com.apple.CoreML/weights/weight.bin", local: "\(part).mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: weights.0, sha256: weights.1),
            ]
        }
        return package("image", manifest: manifests.image, model: models.image, weights: weights.image)
            + package("text", manifest: manifests.text, model: models.text, weights: weights.text)
            + [
                RemoteFile(repository: .tokenizer, path: "vocab.json", local: "vocab.json", size: 862_328, sha256: "5047b556ce86ccaf6aa22b3ffccfc52d391ea4accdab9c2f2407da5b742d4363"),
                RemoteFile(repository: .tokenizer, path: "merges.txt", local: "merges.txt", size: 524_619, sha256: "9fd691f7c8039210e0fced15865466c65820d09b63988b0174bfe25de299051a"),
            ]
    }
}

struct RemoteFile: Sendable {
    enum Repository {
        /// `apple/coreml-mobileclip`: the Core ML encoders.
        case coreML
        /// `apple/MobileCLIP-S2-OpenCLIP`: the tokenizer every MobileCLIP size shares.
        case tokenizer

        var base: String {
            switch self {
            case .coreML: "https://huggingface.co/apple/coreml-mobileclip/resolve/3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947"
            case .tokenizer: "https://huggingface.co/apple/MobileCLIP-S2-OpenCLIP/resolve/8e8a808316aeb7c24d0400e1cf8f74b6937832aa"
            }
        }
    }

    let repository: Repository
    let path: String
    let local: String
    let size: Int64
    let sha256: String

    var url: URL { URL(string: "\(repository.base)/\(path)")! }
}

public enum MobileCLIPError: Error, Sendable {
    case checksumMismatch(String)
    case badResponse(Int)
    case unexpectedOutput
}

/// Where the model lives on this device: one installed size at a time, compiled for Core ML.
/// Nothing here is backed up; it can always be downloaded again.
///
/// In an App Group (``inAppGroup(_:)``), every app with that group shares one copy:
/// `MobileCLIP/installed.json` names the size, and `MobileCLIP/<size>/` holds `image.mlmodelc`,
/// `text.mlmodelc`, `vocab.json` and `merges.txt`. An install or removal in one app applies to all.
public struct MobileCLIPStorage: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The shared copy in `group`, or nil when this app isn't entitled to the group.
    public static func inAppGroup(_ group: String) -> MobileCLIPStorage? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            .map { MobileCLIPStorage(directory: $0.appending(path: "MobileCLIP", directoryHint: .isDirectory)) }
    }

    private var markerFile: URL { directory.appending(path: "installed.json") }

    private func folder(_ variant: MobileCLIPVariant) -> URL {
        directory.appending(path: variant.rawValue, directoryHint: .isDirectory)
    }

    /// The installed size, if a download finished.
    public var installed: MobileCLIPVariant? {
        guard let data = try? Data(contentsOf: markerFile) else { return nil }
        return try? JSONDecoder().decode(MobileCLIPVariant.self, from: data)
    }

    /// Downloads, checks and compiles `variant`, replacing whatever was installed. `progress`
    /// gets the fraction done, from any thread.
    public func install(_ variant: MobileCLIPVariant, progress: @escaping @Sendable (Double) -> Void) async throws {
        let manager = FileManager.default
        let staging = downloadsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        let total = Double(variant.downloadSize)
        var done: Int64 = 0
        let downloader = FileDownloader()
        defer { downloader.finish() }
        for file in variant.files {
            let destination = staging.appending(path: file.local)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let before = done
            try await downloader.download(file.url, to: destination) { written in
                progress(min(Double(before + written) / total, 1) * 0.95)
            }
            guard try await Self.sha256(of: destination) == file.sha256 else {
                throw MobileCLIPError.checksumMismatch(file.path)
            }
            done += file.size
        }

        // Compiled on the device, as Core ML expects; the packages themselves aren't kept.
        let target = folder(variant)
        let built = staging.appending(path: "built", directoryHint: .isDirectory)
        try manager.createDirectory(at: built, withIntermediateDirectories: true)
        for part in ["image", "text"] {
            try Task.checkCancellation()
            let compiled = try await MLModel.compileModel(at: staging.appending(path: "\(part).mlpackage"))
            try manager.moveItem(at: compiled, to: built.appending(path: "\(part).mlmodelc"))
        }
        for name in ["vocab.json", "merges.txt"] {
            try manager.moveItem(at: staging.appending(path: name), to: built.appending(path: name))
        }
        progress(0.99)

        try removeInstalled()
        try manager.moveItem(at: built, to: target)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        try JSONEncoder().encode(variant).write(to: markerFile, options: .atomic)
        progress(1)
    }

    /// Removes the installed model and any download left half-way.
    public func remove() throws {
        try removeInstalled()
        try? FileManager.default.removeItem(at: downloadsDirectory)
    }

    /// Downloads in progress, kept apart so replacing the installed model leaves them alone.
    private var downloadsDirectory: URL { directory.appending(path: "Downloads", directoryHint: .isDirectory) }

    private func removeInstalled() throws {
        let manager = FileManager.default
        try? manager.removeItem(at: markerFile)
        for variant in MobileCLIPVariant.allCases where manager.fileExists(atPath: folder(variant).path()) {
            try manager.removeItem(at: folder(variant))
        }
    }

    /// Loads the installed model. Slow the first time after an install, while Core ML picks
    /// where each layer runs.
    public func load() async throws -> MobileCLIP? {
        guard let variant = installed else { return nil }
        let folder = folder(variant)
        return try await MobileCLIP(variant: variant, folder: folder)
    }

    @concurrent
    private static func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The loaded encoders. An image and a piece of text that describe the same thing come out
/// pointing the same way, so the dot product of two embeddings is how well they match.
public actor MobileCLIP {
    public nonisolated let variant: MobileCLIPVariant
    private let image: MLModel
    private let text: MLModel
    private let tokenizer: CLIPTokenizer
    private let imageConstraint: MLImageConstraint

    init(variant: MobileCLIPVariant, folder: URL) async throws {
        self.variant = variant
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        image = try await MLModel.load(contentsOf: folder.appending(path: "image.mlmodelc"), configuration: configuration)
        text = try await MLModel.load(contentsOf: folder.appending(path: "text.mlmodelc"), configuration: configuration)
        tokenizer = try CLIPTokenizer(vocabulary: folder.appending(path: "vocab.json"), merges: folder.appending(path: "merges.txt"))
        guard let input = image.modelDescription.inputDescriptionsByName.values.first(where: { $0.type == .image }),
              let constraint = input.imageConstraint
        else { throw MobileCLIPError.unexpectedOutput }
        imageConstraint = constraint
    }

    /// The image's embedding, from its centre square scaled to the encoder's 256 pixels.
    public func embed(_ cgImage: CGImage) throws -> [Float] {
        let value = try MLFeatureValue(
            cgImage: cgImage,
            constraint: imageConstraint,
            options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue]
        )
        let name = image.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        let output = try image.prediction(from: MLDictionaryFeatureProvider(dictionary: [name: value]))
        return try Self.normalizedEmbedding(output)
    }

    /// The text's embedding. CLIP learned from English captions, so other languages match poorly.
    public func embed(_ string: String) throws -> [Float] {
        let tokens = tokenizer.encode(string)
        let array = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
        array.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            for (index, token) in tokens.enumerated() { buffer[index] = token }
        }
        let name = text.modelDescription.inputDescriptionsByName.keys.first ?? "text"
        let output = try text.prediction(from: MLDictionaryFeatureProvider(dictionary: [name: MLFeatureValue(multiArray: array)]))
        return try Self.normalizedEmbedding(output)
    }

    private static func normalizedEmbedding(_ output: MLFeatureProvider) throws -> [Float] {
        guard let name = output.featureNames.first, let array = output.featureValue(for: name)?.multiArrayValue else {
            throw MobileCLIPError.unexpectedOutput
        }
        var vector = [Float](repeating: 0, count: array.count)
        switch array.dataType {
        case .float32:
            array.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                for index in vector.indices { vector[index] = buffer[index] }
            }
        default:
            for index in vector.indices { vector[index] = array[index].floatValue }
        }
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard length > 0 else { throw MobileCLIPError.unexpectedOutput }
        return vector.map { $0 / length }
    }
}

/// Downloads one file at a time with progress, through a delegate, since the async
/// `URLSession` calls report none.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        let destination: URL
        let progress: @Sendable (Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    /// Bytes last reported per task; progress goes out every megabyte, not every packet.
    private var reported: [Int: Int64] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let task = lock.withLock { session.downloadTask(with: url) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    pending[task.taskIdentifier] = Pending(destination: destination, progress: progress, continuation: continuation)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func finish() {
        lock.withLock { session }.invalidateAndCancel()
    }

    private func entry(_ task: URLSessionTask, remove: Bool = false) -> Pending? {
        lock.withLock {
            guard remove else { return pending[task.taskIdentifier] }
            reported[task.taskIdentifier] = nil
            return pending.removeValue(forKey: task.taskIdentifier)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let due = lock.withLock {
            guard totalBytesWritten - (reported[downloadTask.taskIdentifier] ?? 0) >= 1_048_576 else { return false }
            reported[downloadTask.taskIdentifier] = totalBytesWritten
            return true
        }
        if due { entry(downloadTask)?.progress(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is gone once this returns, so it moves now.
        guard let pending = entry(downloadTask, remove: true) else { return }
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            pending.continuation.resume(throwing: MobileCLIPError.badResponse(response.statusCode))
            return
        }
        do {
            try? FileManager.default.removeItem(at: pending.destination)
            try FileManager.default.moveItem(at: location, to: pending.destination)
            pending.continuation.resume()
        } catch {
            pending.continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success already resumed in `didFinishDownloadingTo`; this only reports failures.
        guard let pending = entry(task, remove: true) else { return }
        pending.continuation.resume(throwing: error ?? URLError(.unknown))
    }
}
