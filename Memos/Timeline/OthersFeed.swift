import MemosCore
import SwiftUI

/// Pages through other people's memos for one timeline (a scope, Space and filter). Your own
/// memos come from the local copy; this fills in everyone else's, newest first, and caches
/// them for reading offline.
@Observable
final class OthersFeed {
    struct Key: Equatable {
        var space: String?
        var filter: String?
    }

    private(set) var key: Key?
    private(set) var isLoading = false
    private(set) var hasMore = true
    /// The oldest memo loaded so far. Your own memos older than this wait until the next page,
    /// so the merged timeline never shows a gap.
    private(set) var oldestLoaded: Date?
    private(set) var failed = false
    /// Every memo the pages returned, in server order. Used for filters the device can't
    /// evaluate, where the server's list is the whole timeline.
    private(set) var serverOnly: [Memo] = []
    @ObservationIgnored private var pageToken = ""
    /// Bumped on every reset, so a page requested before it is ignored.
    @ObservationIgnored private var generation = 0

    /// Starts over when the timeline's Space or filter changed.
    func reset(to key: Key) {
        guard key != self.key else { return }
        self.key = key
        generation += 1
        isLoading = false
        pageToken = ""
        hasMore = true
        oldestLoaded = nil
        failed = false
        serverOnly = []
    }

    /// Starts the same timeline over from its first page.
    func reload() {
        guard let key else { return }
        self.key = nil
        reset(to: key)
    }

    /// Loads the next page. `includeOwn` asks for your memos too, when the device can't
    /// evaluate the filter itself.
    /// Does nothing without an engine (the on-device library), which has nobody else to fetch.
    func loadMore(using engine: SyncEngine?, me: String, includeOwn: Bool = false) async {
        guard let engine, let key, hasMore, !isLoading, engine.isOnline else { return }
        let generation = self.generation
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }
        var clauses = includeOwn ? [] : ["creator != \(CELString.quote(me))"]
        if let space = key.space { clauses.append("space == \(CELString.quote(space))") }
        if let filter = key.filter { clauses.append("(\(filter))") }
        do {
            let page = try await engine.fetchPage(filter: clauses.isEmpty ? nil : clauses.joined(separator: " && "), pageToken: pageToken)
            guard generation == self.generation else { return }
            serverOnly += page.memos
            pageToken = page.nextPageToken
            hasMore = !page.nextPageToken.isEmpty
            if let oldest = page.memos.map(\.createdAt).min() {
                oldestLoaded = min(oldest, oldestLoaded ?? oldest)
            }
            failed = false
        } catch {
            failed = true
        }
    }

    /// Merges your memos with loaded pages, cutting off below the oldest loaded memo while more
    /// pages remain.
    func visible(_ memos: [Memo], online: Bool) -> [Memo] {
        guard online, hasMore, let oldestLoaded else { return memos }
        return memos.filter { $0.createdAt >= oldestLoaded }
    }
}
