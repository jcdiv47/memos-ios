import ImageIO
import MemosCore
import SwiftUI
import UniformTypeIdentifiers

/// Downloads and caches attachment files. Thumbnails of your own memos download in the
/// background; full-size files are cached as you open them, up to 500 MB, oldest first out.
/// “Keep all attachments” downloads everything for travel. In the on-device library every file is
/// already here, and nothing downloads.
@Observable
final class AttachmentFiles {
    /// Nil for the on-device library.
    private let client: MemosClient?
    private let store: MemoStore
    @ObservationIgnored private let images = NSCache<NSString, UIImage>()
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    static let fullSizeLimit: Int64 = 500 * 1024 * 1024

    var keepAll: Bool {
        didSet {
            UserDefaults.standard.set(keepAll, forKey: "attachments.keepAll")
            if keepAll { prefetchThumbnails() }
        }
    }

    init(client: MemosClient?, store: MemoStore) {
        self.client = client
        self.store = store
        keepAll = UserDefaults.standard.bool(forKey: "attachments.keepAll")
        images.countLimit = 300
    }

    private var thumbnailsDirectory: URL { store.location.filesDirectory.appending(path: "thumbs", directoryHint: .isDirectory) }
    private var fullDirectory: URL { store.location.filesDirectory.appending(path: "full", directoryHint: .isDirectory) }

    private func thumbnailFile(_ attachment: Attachment) -> URL {
        thumbnailsDirectory.appending(path: ResourceName.lastSegment(attachment.name))
    }

    private func fullFile(_ attachment: Attachment) -> URL {
        fullDirectory.appending(path: ResourceName.lastSegment(attachment.name), directoryHint: .isDirectory)
            .appending(path: attachment.filename.isEmpty ? "file" : attachment.filename)
    }

    func remoteURL(_ attachment: Attachment, thumbnail: Bool) -> URL? {
        if !attachment.externalLink.isEmpty { return URL(string: attachment.externalLink) }
        guard let client else { return nil }
        var url = client.serverURL.appending(path: "file").appending(path: attachment.name)
        if !attachment.filename.isEmpty { url.append(path: attachment.filename) }
        if thumbnail { url.append(queryItems: [URLQueryItem(name: "thumbnail", value: "true")]) }
        return url
    }

    // MARK: Images

    func cachedImage(_ attachment: Attachment, thumbnail: Bool) -> UIImage? {
        images.object(forKey: key(attachment, thumbnail: thumbnail))
    }

    /// The image for `attachment`: the staged file while it waits to upload, otherwise the cached
    /// or downloaded thumbnail or full-size file.
    func image(_ attachment: Attachment, thumbnail: Bool = true) async -> UIImage? {
        if let cached = cachedImage(attachment, thumbnail: thumbnail) { return cached }
        guard let url = try? await file(attachment, thumbnail: thumbnail),
              let image = await Self.decode(url, maxPixelSize: thumbnail ? 900 : 3000)
        else { return nil }
        images.setObject(image, forKey: key(attachment, thumbnail: thumbnail))
        return image
    }

    private func key(_ attachment: Attachment, thumbnail: Bool) -> NSString {
        "\(attachment.name)#\(thumbnail)" as NSString
    }

    @concurrent
    private static func decode(_ url: URL, maxPixelSize: Int) async -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    // MARK: Files

    /// A local file for `attachment`, downloading it if needed.
    func file(_ attachment: Attachment, thumbnail: Bool = false) async throws -> URL {
        if store.isStaged(attachment) {
            return store.location.uploadFile(for: attachment.name)
        }
        let isImage = attachment.type.hasPrefix("image/")
        let wantsThumbnail = thumbnail && isImage && attachment.externalLink.isEmpty
        let destination = wantsThumbnail ? thumbnailFile(attachment) : fullFile(attachment)
        if FileManager.default.fileExists(atPath: destination.path()) {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: destination.path())
            return destination
        }
        // A full-size file already on disk serves as its own thumbnail.
        if wantsThumbnail, FileManager.default.fileExists(atPath: fullFile(attachment).path()) {
            return fullFile(attachment)
        }
        guard let url = remoteURL(attachment, thumbnail: wantsThumbnail) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        if attachment.externalLink.isEmpty, let client {
            request = try await client.authorizedRequest(for: url)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
            throw URLError(.badServerResponse)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        if !wantsThumbnail && !keepAll {
            await Self.trim(fullDirectory, limit: Self.fullSizeLimit)
        }
        return destination
    }

    /// Removes the least recently used full-size files until the cache fits.
    @concurrent
    private static func trim(_ directory: URL, limit: Int64) async {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        for case let url as URL in enumerator.allObjects {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.date < $1.date }) where total > limit {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    /// Downloads thumbnails for your memos' images, and every file when “Keep all attachments”
    /// is on. Runs in the background after a sync.
    func prefetchThumbnails() {
        guard prefetchTask == nil, client != nil else { return }
        let attachments = store.own.values.flatMap(\.attachments).filter { !store.isStaged($0) }
        let keepAll = self.keepAll
        prefetchTask = Task { [weak self] in
            defer { self?.prefetchTask = nil }
            for attachment in attachments {
                guard let self, !Task.isCancelled, self.store.isLoaded else { return }
                if attachment.type.hasPrefix("image/") {
                    _ = try? await self.file(attachment, thumbnail: true)
                }
                if keepAll {
                    _ = try? await self.file(attachment, thumbnail: false)
                }
            }
        }
    }

    /// Bytes used by downloaded files, for Settings.
    func cacheSize() async -> Int64 {
        await Self.size(of: store.location.filesDirectory)
    }

    /// Bytes used by the whole library, attachments included, for the on-device library's Settings.
    func librarySize() async -> Int64 {
        await Self.size(of: store.location.directory)
    }

    @concurrent
    private static func size(of directory: URL) async -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator.allObjects {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

extension Attachment {
    var isImage: Bool { type.hasPrefix("image/") }
    var isAudio: Bool { type.hasPrefix("audio/") }
    var isVideo: Bool { type.hasPrefix("video/") }

    var systemImage: String {
        if isImage { return "photo" }
        if isAudio { return "waveform" }
        if isVideo { return "film" }
        if type == "application/pdf" { return "doc.richtext" }
        return "doc"
    }
}
