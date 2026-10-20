import AppIntents
import CoreSpotlight
import MemosCore

/// Keeps Spotlight's copy of your memos current, through the same entities Shortcuts sees.
enum SpotlightIndex {
    static func update(_ store: MemoStore) {
        let entities = store.own.values.filter { !$0.isArchived }.map(MemoEntity.init)
        Task(priority: .background) { await index(entities) }
    }

    @concurrent
    private static func index(_ entities: [MemoEntity]) async {
        try? await CSSearchableIndex.default().indexAppEntities(entities)
    }
}
