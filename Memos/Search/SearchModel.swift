import MemosCore
import SwiftUI

/// What's in the search field and what it found. Your own matches come straight from the local
/// copy on every keystroke; other people's arrive from the server after a 150 ms pause.
@Observable
final class SearchModel {
    var text = "" {
        didSet { if text != oldValue { textChanged() } }
    }
    var tokens: [SearchToken] = [] {
        didSet { if tokens != oldValue { scheduleRemote() } }
    }
    var scope: MemoQuery.Scope = .mine {
        didSet { if scope != oldValue { scheduleRemote() } }
    }

    private(set) var remote: [Memo] = []
    private(set) var isLoadingRemote = false
    private(set) var remoteFailed = false
    private(set) var recents: [String] = UserDefaults.standard.stringArray(forKey: "search.recents") ?? []

    @ObservationIgnored private weak var session: AccountSession?
    @ObservationIgnored private var remoteTask: Task<Void, Never>?
    /// Where the server's next page of other people's matches starts; empty when there isn't one.
    private(set) var remoteNextPageToken = ""
    @ObservationIgnored private var remoteFilter = ""

    var query: SearchQuery { SearchQuery(text: text, tokens: tokens) }

    /// Called when search opens: starts from the title menu's scope, with the selected Space as
    /// a token you can remove to search every Space.
    func begin(in session: AccountSession) {
        self.session = session
        scope = session.effectiveScope
        if let space = session.space(named: session.selectedSpace),
           !tokens.contains(where: { if case .space = $0 { true } else { false } }) {
            tokens.insert(.space(name: space.name, title: space.title), at: 0)
        }
    }

    func end() {
        remember()
        remoteTask?.cancel()
        text = ""
        tokens = []
        remote = []
    }

    // MARK: Typing

    private func textChanged() {
        // Typing #word turns into a tag token once it's followed by a space.
        if let range = text.range(of: #"(^|\s)#([^\s#]+)\s$"#, options: .regularExpression) {
            let tag = text[range].trimmingCharacters(in: .whitespaces).dropFirst()
            text.removeSubrange(range)
            if !tokens.contains(.tag(String(tag))) { tokens.append(.tag(String(tag))) }
        }
        scheduleRemote()
    }

    /// The partial tag being typed, for tag suggestions.
    var typedTagPrefix: String? {
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("#") else { return nil }
        return String(last.dropFirst())
    }

    func addToken(_ token: SearchToken) {
        if let prefix = typedTagPrefix {
            text.removeLast(prefix.count + 1)
        }
        if !tokens.contains(token) { tokens.append(token) }
    }

    func applyRecent(_ recent: String) {
        let parts = recent.split(separator: " ")
        tokens = tokens.filter { if case .space = $0 { true } else { false } } + parts.filter { $0.hasPrefix("#") }.map { .tag(String($0.dropFirst())) }
        text = parts.filter { !$0.hasPrefix("#") }.joined(separator: " ")
    }

    // MARK: Results

    func ownResults(in session: AccountSession) -> [Memo] {
        guard let filter = query.filter(), let parsed = try? MemoFilter(filter) else { return [] }
        return session.memos(MemoQuery(scope: .mine, filter: parsed, order: .newest))
    }

    /// Other people's matches: from the server when online, otherwise from what's cached.
    func otherResults(in session: AccountSession) -> [Memo] {
        guard scope == .everyone, session.showsScopeToggle else { return [] }
        if session.isOnline { return remote }
        guard let filter = query.filter(), let parsed = try? MemoFilter(filter) else { return [] }
        return session.memos(MemoQuery(scope: .others, filter: parsed))
    }

    private func scheduleRemote() {
        remoteTask?.cancel()
        guard let session, scope == .everyone, session.showsScopeToggle, let filter = query.filter() else {
            remote = []
            remoteNextPageToken = ""
            return
        }
        let me = session.user
        remoteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, session.isOnline, let engine = session.engine else { return }
            self.isLoadingRemote = true
            defer { self.isLoadingRemote = false }
            do {
                let remoteFilter = "(\(filter)) && creator != \(CELString.quote(me))"
                let page = try await engine.fetchPage(filter: remoteFilter, pageSize: 50)
                guard !Task.isCancelled else { return }
                self.remote = page.memos
                self.remoteFilter = remoteFilter
                self.remoteNextPageToken = page.nextPageToken
                self.remoteFailed = false
            } catch {
                self.remoteFailed = true
            }
        }
    }

    /// The next page of other people's matches, when the list reaches the last one loaded.
    func loadMoreRemote() {
        guard let session, let engine = session.engine, !remoteNextPageToken.isEmpty, !isLoadingRemote, session.isOnline else { return }
        let token = remoteNextPageToken
        let filter = remoteFilter
        remoteTask = Task { [weak self] in
            guard let self else { return }
            self.isLoadingRemote = true
            defer { self.isLoadingRemote = false }
            do {
                let page = try await engine.fetchPage(filter: filter, pageToken: token, pageSize: 50)
                // A new query started meanwhile; its results replace these.
                guard !Task.isCancelled, filter == self.remoteFilter else { return }
                let seen = Set(self.remote.map(\.name))
                self.remote += page.memos.filter { !seen.contains($0.name) }
                self.remoteNextPageToken = page.nextPageToken
            } catch {
                self.remoteFailed = true
            }
        }
    }

    // MARK: Recents

    /// Keeps the last 10 searches on this device.
    private func remember() {
        let entry = (tokens.compactMap { if case .tag(let tag) = $0 { "#\(tag)" } else { nil } } + [text.trimmingCharacters(in: .whitespaces)])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !entry.isEmpty else { return }
        recents.removeAll { $0 == entry }
        recents.insert(entry, at: 0)
        recents = Array(recents.prefix(10))
        UserDefaults.standard.set(recents, forKey: "search.recents")
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: "search.recents")
    }
}
