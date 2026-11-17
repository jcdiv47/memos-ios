import AppIntents
import CoreSpotlight
import MemosCore

/// Keeps Spotlight's copy of your memos current, through the same entities Shortcuts sees.
enum SpotlightIndex {
    static func update(_ store: MemoStore) {
        // Re-indexing by the same ID also redacts a memo indexed before its tag was set to blur.
        let rules = store.profile.tagBlurRules
        let entities = store.own.values.filter { !$0.isArchived }.map { MemoEntity($0, rules: rules) }
        Task(priority: .background) { await index(entities) }
    }

    @concurrent
    private static func index(_ entities: [MemoEntity]) async {
        try? await CSSearchableIndex.default().indexAppEntities(entities)
    }
}
