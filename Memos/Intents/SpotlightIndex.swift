import AppIntents
import CoreSpotlight
import MemosCore
import OSLog

/// Keeps Spotlight's copy of your memos current, through the same entities Shortcuts sees.
enum SpotlightIndex {
    private nonisolated static let logger = Logger(subsystem: "app.memos", category: "spotlight")

    /// The last queued change. Each waits for the one before, so clearing the index when one
    /// library closes can't land after the next library is indexed.
    private static var queue: Task<Void, Never>?

    private static func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = queue
        queue = Task(priority: .background) {
            await previous?.value
            await work()
        }
    }

    static func update(_ store: MemoStore) {
        // Re-indexing by the same ID also redacts a memo indexed before its tag was set to blur.
        let entities = store.own.values.filter { !$0.isArchived }.map { MemoEntity($0, rules: store.profile.tagBlurRules) }
        enqueue { await index(entities) }
    }

    /// Swaps in `store`'s memos for whatever library was indexed before.
    static func replace(with store: MemoStore) {
        let entities = store.own.values.filter { !$0.isArchived }.map { MemoEntity($0, rules: store.profile.tagBlurRules) }
        enqueue {
            await removeAll()
            await index(entities)
        }
    }

    /// Removes every memo, once the library they belong to is gone.
    static func clear() {
        enqueue { await removeAll() }
    }

    @concurrent
    private static func removeAll() async {
        do {
            try await CSSearchableIndex.default().deleteAppEntities(ofType: MemoEntity.self)
        } catch {
            logger.error("Clearing the index failed: \(error)")
        }
    }

    /// Waits for Spotlight to take the memos, for callers that must finish before suspension.
    static func reindex(_ store: MemoStore) async {
        let entities = store.own.values.filter { !$0.isArchived }.map { MemoEntity($0, rules: store.profile.tagBlurRules) }
        enqueue { await index(entities) }
        await queue?.value
    }

    @concurrent
    private static func index(_ entities: [MemoEntity]) async {
        do {
            try await CSSearchableIndex.default().indexAppEntities(entities)
        } catch {
            logger.error("Indexing failed: \(error)")
        }
    }
}
