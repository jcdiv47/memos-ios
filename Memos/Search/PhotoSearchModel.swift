import ImageIO
import MemosCore
import PhotoSearch
import SwiftUI

/// Finding your photos by describing them. Off until you download Apple's MobileCLIP in
/// Settings; then each photo in your memos becomes an embedding on this iPhone, and search
/// compares what you type against them. Nothing leaves the device but the one download.
@Observable
final class PhotoSearchModel {
    /// The size that's installed, or nil while photo search is off.
    private(set) var installed: MobileCLIPVariant?
    /// How far the download has got, while one runs.
    private(set) var downloadProgress: Double?
    var error: String?
    /// Photos with an embedding, out of all the photos in your memos.
    private(set) var indexedCount = 0
    private(set) var photoCount = 0
    private(set) var isIndexing = false

    var isReady: Bool { installed != nil }

    /// One copy of the model for every account, in an App Group your other apps can share
    /// (`MobileCLIPAppGroup` in Info.plist). It isn't backed up; it can be downloaded again.
    static let storage: MobileCLIPStorage = {
        let group = Bundle.main.object(forInfoDictionaryKey: "MobileCLIPAppGroup") as? String
        return group.flatMap(MobileCLIPStorage.inAppGroup)
            ?? MobileCLIPStorage(directory: URL.applicationSupportDirectory.appending(path: "MobileCLIP", directoryHint: .isDirectory))
    }()

    @ObservationIgnored private let store: MemoStore
    @ObservationIgnored private let files: AttachmentFiles
    @ObservationIgnored private var model: Task<MobileCLIP?, Never>?
    @ObservationIgnored private var index: PhotoIndex?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherPass = false
    /// Set on sign-out; no pass starts after it.
    @ObservationIgnored private var isStopped = false
    /// Photos that couldn't be read this session, so each pass doesn't try them again.
    @ObservationIgnored private var unreadable: Set<String> = []
    /// Text embeddings for recent searches, since typing back over a word asks again.
    @ObservationIgnored private var queries: [String: [Float]] = [:]

    init(store: MemoStore, files: AttachmentFiles) {
        self.store = store
        self.files = files
        installed = Self.storage.installed
    }

    /// Kept with the account's local copy, so signing out removes it too.
    private var indexFile: URL { store.location.directory.appending(path: "PhotoIndex.plist") }

    // MARK: Download

    func download(_ variant: MobileCLIPVariant) {
        guard downloadTask == nil else { return }
        error = nil
        downloadProgress = 0
        downloadTask = Task { [weak self] in
            do {
                try await Self.storage.install(variant) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        if self?.downloadTask != nil { self?.downloadProgress = fraction }
                    }
                }
                guard let self else { return }
                self.reset()
                self.installed = variant
                self.indexIfNeeded()
            } catch {
                guard let self else { return }
                if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                    self.error = Self.describe(error)
                }
            }
            self?.downloadProgress = nil
            self?.downloadTask = nil
        }
    }

    /// Picks up a model another app sharing the group installed, replaced or removed.
    func refresh() {
        let current = Self.storage.installed
        guard current != installed, downloadTask == nil else { return }
        reset()
        installed = current
        indexedCount = 0
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Turns photo search off and frees the space the model takes.
    func remove() {
        downloadTask?.cancel()
        reset()
        installed = nil
        indexedCount = 0
        try? FileManager.default.removeItem(at: indexFile)
        do {
            try Self.storage.remove()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reset() {
        indexTask?.cancel()
        indexTask = nil
        needsAnotherPass = false
        isIndexing = false
        model = nil
        index = nil
        queries = [:]
        unreadable = []
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case MobileCLIPError.checksumMismatch:
            String(localized: "The download didn’t match what Apple published, so it wasn’t installed. Try again.")
        case let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost:
            String(localized: "The download stopped because the connection dropped. Try again.")
        default:
            String(localized: "Couldn’t download the model. \(error.localizedDescription)")
        }
    }

    /// The model, loaded once. Loading takes a moment, so it starts with the first need.
    private func loadedModel() async -> MobileCLIP? {
        guard installed != nil else { return nil }
        if model == nil {
            model = Task { try? await Self.storage.load() }
        }
        return await model?.value
    }

    // MARK: Indexing

    /// Embeds the photos in your memos that don't have one yet, from their thumbnails, and
    /// forgets photos that are gone. Runs after launch and foreground syncs, and when search
    /// opens, so photos from any other sync are searchable by then.
    func indexIfNeeded() {
        guard installed != nil, store.isLoaded, !isStopped else { return }
        // Photos that arrived after a running pass listed them get a pass of their own.
        guard indexTask == nil else {
            needsAnotherPass = true
            return
        }
        indexTask = Task { [weak self] in
            await self?.buildIndex()
            // A cancelled pass was replaced, and the new one owns these.
            guard let self, !Task.isCancelled else { return }
            self.isIndexing = false
            self.indexTask = nil
            if self.needsAnotherPass {
                self.needsAnotherPass = false
                self.indexIfNeeded()
            }
        }
    }

    /// Stops indexing and waits for it, so no write lands after the account's folder is gone.
    func stop() async {
        isStopped = true
        let task = indexTask
        task?.cancel()
        needsAnotherPass = false
        await task?.value
    }

    private func buildIndex() async {
        guard let model = await self.loadedModel(), !Task.isCancelled else { return }
        if self.index?.variant != model.variant {
            self.index = await Self.read(self.indexFile, variant: model.variant) ?? PhotoIndex(variant: model.variant)
        }
        let photos = self.photos()
        self.index?.keep(only: Set(photos.map(\.name)))
        self.photoCount = photos.count
        self.indexedCount = self.index?.count ?? 0
        let missing = photos.filter { self.index?.contains($0.name) == false && !self.unreadable.contains($0.name) }
        self.isIndexing = !missing.isEmpty
        var unsaved = 0
        for photo in missing {
            guard !Task.isCancelled else { break }
            // A download that fails, offline say, is tried again next pass; a file that won't
            // decode isn't, until the next launch.
            guard let file = try? await self.files.file(photo, thumbnail: true) else { continue }
            guard let image = await Self.decode(file), let embedding = try? await model.embed(image) else {
                self.unreadable.insert(photo.name)
                continue
            }
            guard !Task.isCancelled else { break }
            self.index?.set(embedding, for: photo.name)
            self.indexedCount = self.index?.count ?? 0
            unsaved += 1
            if unsaved >= 25, let index = self.index {
                await Self.write(index, to: self.indexFile)
                unsaved = 0
            }
        }
        if !Task.isCancelled, let index = self.index {
            await Self.write(index, to: self.indexFile)
        }
    }

    /// Every image attached to your memos, once each.
    private func photos() -> [Attachment] {
        var seen: Set<String> = []
        return store.own.values
            .sorted { $0.createdAt > $1.createdAt }
            .flatMap(\.attachments)
            .filter { $0.isImage && seen.insert($0.name).inserted }
    }

    @concurrent
    private static func decode(_ url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Twice the encoder's 256 pixels is plenty for it to crop and scale from.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    @concurrent
    private static func read(_ url: URL, variant: MobileCLIPVariant) async -> PhotoIndex? {
        PhotoIndex.read(url, variant: variant)
    }

    @concurrent
    private static func write(_ index: PhotoIndex, to url: URL) async {
        try? index.write(to: url)
    }

    // MARK: Searching

    struct Match: Identifiable, Equatable {
        let memo: Memo
        let attachment: Attachment
        var id: String { attachment.name }
    }

    /// The photos in `memos` that look like `text`, best first.
    func matches(for text: String, in memos: [Memo]) async -> [Match] {
        guard let model = await loadedModel(), let index, index.count > 0 else { return [] }
        let query: [Float]
        if let cached = queries[text] {
            query = cached
        } else {
            guard let embedding = try? await model.embed(text) else { return [] }
            if queries.count > 50 { queries = [:] }
            queries[text] = embedding
            query = embedding
        }
        var owners: [String: Match] = [:]
        for memo in memos {
            for attachment in memo.attachments where attachment.isImage {
                owners[attachment.name] = Match(memo: memo, attachment: attachment)
            }
        }
        return index.matches(for: query, among: Set(owners.keys)).compactMap { owners[$0.name] }
    }
}
