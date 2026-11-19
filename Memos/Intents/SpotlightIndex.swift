import AppIntents
import CoreSpotlight
import MemosCore
import OSLog

/// Keeps Spotlight's copy of your memos current, through the same entities Shortcuts sees.
enum SpotlightIndex {
    private nonisolated static let logger = Logger(subsystem: "app.memos", category: "spotlight")

    static func update(_ store: MemoStore) {
        Task(priority: .background) { await reindex(store) }
    }

    /// Waits for Spotlight to take the memos, for callers that must finish before suspension.
    static func reindex(_ store: MemoStore) async {
        let entities = store.own.values.filter { !$0.isArchived }.map(MemoEntity.init)
        await index(entities)
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
