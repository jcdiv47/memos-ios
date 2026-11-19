import Foundation
import Observation
import SwiftProtobuf

/// The local copy of one account: every memo you wrote (archived ones included), the other
/// people's memos you've seen, and the queue of changes waiting to upload.
///
/// Every edit lands here first and shows immediately; ``SyncEngine`` uploads the queue and
/// folds server changes back in. Server data never overwrites a memo with queued changes —
/// those are reconciled when the change uploads.
///
/// The on-device library (``AccountLocation/isOnDevice``) uses the same store with no queue: its
/// edits are final as they land, and its attachments stay in the upload area for good.
@MainActor
@Observable
public final class MemoStore {
    public let location: AccountLocation
    /// Resource name of the signed-in user.
    public var user: String { location.user }
    /// Whether this is the on-device library, which never uploads.
    public var isOnDevice: Bool { location.isOnDevice }

    public private(set) var own: [String: Memo] = [:]
    public private(set) var others: [String: Memo] = [:]
    public internal(set) var state = SyncState() {
        didSet { schedulePersist(.state) }
    }
    public var profile = ProfileCache() {
        didSet { if profile != oldValue { schedulePersist(.profile) } }
    }
    public private(set) var isLoaded = false
    /// Bumped on every memo change, so derived lists can cache against it.
    public private(set) var revision = 0

    /// Called after every local change, so the sync engine can start uploading.
    @ObservationIgnored public var onLocalChange: (@MainActor () -> Void)?
    /// The change ``SyncEngine`` is uploading right now. Never merged into.
    @ObservationIgnored var inFlight: UUID?

    @ObservationIgnored private var dirty: Persisted = []
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    /// The write in progress. Writes run one after another, so an older snapshot never lands
    /// after a newer one.
    @ObservationIgnored private var writing: Task<Void, Never>?

    struct Persisted: OptionSet {
        let rawValue: Int
        static let own = Persisted(rawValue: 1)
        static let others = Persisted(rawValue: 2)
        static let state = Persisted(rawValue: 4)
        static let profile = Persisted(rawValue: 8)
        static let all: Persisted = [.own, .others, .state, .profile]
    }

    /// The most other people's memos kept for offline reading, newest first.
    static let othersCacheLimit = 3000

    public init(location: AccountLocation) {
        self.location = location
    }

    public func load() async {
        guard !isLoaded else { return }
        let snapshot = await AccountArchive.read(location)
        own = Dictionary(snapshot.own.map { ($0.name, $0) }, uniquingKeysWith: { $1 })
        others = Dictionary(snapshot.others.map { ($0.name, $0) }, uniquingKeysWith: { $1 })
        state = snapshot.state
        profile = snapshot.profile
        if isOnDevice && profile.user == nil {
            // So everything that waits for the profile to load knows it has.
            var me = User()
            me.name = user
            me.username = ResourceName.lastSegment(user)
            profile.user = me
        }
        dirty = []
        isLoaded = true
        revision += 1
    }

    /// Writes anything not yet on disk. Call when the app moves to the background.
    public func save() async {
        persistTask?.cancel()
        persistTask = nil
        await writeDirty()
    }

    // MARK: Reading

    public func memo(named name: String) -> Memo? {
        own[name] ?? others[name]
    }

    public var outbox: [PendingChange] { state.outbox }

    /// Whether the memo has changes waiting to upload. Shown as a small clock on its card.
    public func isWaitingToSync(_ name: String) -> Bool {
        state.outbox.contains { $0.memo == name }
    }

    public func failedChange(for name: String) -> PendingChange? {
        state.outbox.first { $0.memo == name && $0.failure != nil }
    }

    /// The other half of a memo split by a text conflict, if this memo is one.
    public func conflictCounterpart(of name: String) -> String? {
        state.conflicts[name]
    }

    /// Memos for a timeline, search or saved view, in timeline order.
    public func memos(_ query: MemoQuery, now: Date = .now) -> [Memo] {
        var candidates: [Memo]
        switch query.scope {
        case .mine:
            candidates = own.values.filter { $0.state == query.state }
        case .everyone:
            candidates = own.values.filter { $0.state == query.state }
            if query.state == .normal {
                candidates += others.values.filter { $0.state == .normal && $0.creator != user }
            }
        case .others:
            candidates = others.values.filter { $0.state == .normal && $0.creator != user }
        }
        if let space = query.space {
            candidates.removeAll { $0.spaceName != space }
        }
        if let filter = query.filter {
            candidates.removeAll { (try? filter.matches($0.facts, now: now)) != true }
        }
        return candidates.sorted(by: query.order.areInIncreasingOrder)
    }

    /// Your memos per Space, for the title menu. The key nil counts every Space.
    public func ownCounts() -> [String?: Int] {
        var counts: [String?: Int] = [nil: 0]
        for memo in own.values where memo.state == .normal {
            counts[nil, default: 0] += 1
            if let space = memo.spaceName { counts[space, default: 0] += 1 }
        }
        return counts
    }

    /// How many of your memos carry each tag, most-used first.
    public func tagCounts() -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for memo in own.values where memo.state == .normal {
            for tag in memo.facts.tags { counts[tag, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    // MARK: Local changes

    /// Copies a file into the upload area and returns the attachment that stands in for it until
    /// it uploads. Pass the result in ``MemoDraft/attachments``.
    public func stageUpload(data: Data, filename: String, mimeType: String, attachmentID: String? = nil) throws -> Attachment {
        let uid = attachmentID ?? ResourceID.generate()
        var attachment = Attachment()
        attachment.name = "attachments/\(uid)"
        attachment.filename = filename
        attachment.type = mimeType
        attachment.size = Int64(data.count)
        attachment.creator = user
        attachment.createTime = Google_Protobuf_Timestamp(date: .now)
        try FileManager.default.createDirectory(at: location.uploadsDirectory, withIntermediateDirectories: true)
        try data.write(to: location.uploadFile(for: attachment.name), options: .atomic)
        return attachment
    }

    /// Whether `attachment` exists only on this device so far. Always so in the on-device library.
    public func isStaged(_ attachment: Attachment) -> Bool {
        FileManager.default.fileExists(atPath: location.uploadFile(for: attachment.name).path())
    }

    /// Creates a memo locally and queues its upload. The ID is picked here so a retried upload
    /// can't create a duplicate.
    @discardableResult
    public func create(_ draft: MemoDraft) -> Memo {
        var memo = Memo()
        memo.name = "memos/\(draft.uid ?? ResourceID.generate())"
        memo.creator = user
        memo.content = draft.content
        memo.visibility = draft.visibility
        memo.state = .normal
        memo.pinned = draft.pinned
        memo.spaceName = draft.space
        if let location = draft.location { memo.location = location }
        memo.attachments = draft.attachments
        memo.createTime = Google_Protobuf_Timestamp(date: draft.createdAt)
        memo.updateTime = memo.createTime
        memo.refreshDerivedFields()
        memo.setReferences(draft.references)
        own[memo.name] = memo
        if !draft.references.isEmpty { reflectReferences(of: [memo]) }

        for attachment in draft.attachments where isStaged(attachment) {
            queue(PendingChange(memo: memo.name, operation: .uploadAttachment(attachment: attachment.name)))
        }
        queue(PendingChange(memo: memo.name, operation: .create))
        didChange(own: true)
        return memo
    }

    /// Applies `edit` to one of your memos and queues the fields it touched. `base` is the
    /// version the edit started from, when that's older than the current local copy (a composer
    /// that was open while a sync brought in someone else's text).
    public func update(_ name: String, fields: Set<MemoField>, base explicitBase: BaseVersion? = nil, _ edit: (inout Memo) -> Void) {
        guard var memo = own[name] else { return }
        let before = memo
        edit(&memo)
        var fields = fields
        // The server refuses to move a Space-visibility memo unless the visibility is sent too.
        if fields.contains(.space) || fields.contains(.visibility) { fields.formUnion([.space, .visibility]) }
        if memo.content != before.content { memo.refreshDerivedFields() }
        // With no server to stamp it, the edit time is set here. Like the server, pinning and
        // archiving don't count as edits.
        if isOnDevice && !fields.isSubset(of: [.pinned, .state]) {
            memo.updateTime = Google_Protobuf_Timestamp(date: .now)
        }
        own[name] = memo
        if memo.references != before.references || (memo.snippet != before.snippet && !memo.references.isEmpty) {
            reflectReferences(of: [memo])
        }

        if isOnDevice {
            // Nothing else holds a removed attachment's file.
            for attachment in before.attachments where !memo.attachments.contains(where: { $0.name == attachment.name }) {
                try? FileManager.default.removeItem(at: location.uploadFile(for: attachment.name))
            }
        }
        let newUploads = memo.attachments.filter { attachment in
            isStaged(attachment) && !before.attachments.contains { $0.name == attachment.name }
        }
        for attachment in newUploads {
            queue(PendingChange(memo: name, operation: .uploadAttachment(attachment: attachment.name)))
        }
        let base = fields.contains(.content) ? explicitBase ?? BaseVersion(updateTime: before.updatedAt, content: before.content) : nil
        queue(PendingChange(memo: name, operation: .update(fields: fields, base: base)))
        didChange(own: true)
    }

    public func setContent(_ name: String, to content: String) {
        update(name, fields: [.content]) { $0.content = content }
    }

    public func setPinned(_ name: String, _ pinned: Bool) {
        update(name, fields: [.pinned]) { $0.pinned = pinned }
    }

    public func setArchived(_ name: String, _ archived: Bool) {
        update(name, fields: [.state]) { $0.state = archived ? .archived : .normal }
    }

    /// Moves a memo between Spaces and audiences. Removing the Space turns Space visibility
    /// into Private, as the web does.
    public func setAudience(_ name: String, visibility: MemoVisibility, space: String?) {
        update(name, fields: [.visibility, .space]) { memo in
            memo.spaceName = space
            memo.visibility = space == nil ? VisibilityRules.afterRemovingSpace(visibility) : visibility
        }
    }

    public func setLocation(_ name: String, _ location: MemoLocation?) {
        update(name, fields: [.location]) { memo in
            if let location { memo.location = location } else { memo.clearLocation() }
        }
    }

    /// Checks or unchecks the task on `line`. The content updates right away and syncs in the
    /// background.
    public func toggleTask(_ name: String, line: Int) {
        guard let memo = own[name] else { return }
        let content = MarkdownEditing.toggleTask(atLine: line, in: memo.content)
        guard content != memo.content else { return }
        setContent(name, to: content)
    }

    public func delete(_ name: String) {
        guard let memo = own.removeValue(forKey: name) else { return }
        for attachment in memo.attachments where isStaged(attachment) {
            try? FileManager.default.removeItem(at: location.uploadFile(for: attachment.name))
        }
        queue(PendingChange(memo: name, operation: .delete))
        state.conflicts[name] = nil
        reflectReferences(of: [(name, "", [])])
        didChange(own: true)
    }

    /// Clears the “Edited on another device” banner on both memos of a conflict pair.
    public func dismissConflict(_ name: String) {
        if let counterpart = state.conflicts.removeValue(forKey: name) {
            state.conflicts[counterpart] = nil
        }
    }

    /// Drops a change the server keeps rejecting. The local memo is refreshed on the next sync.
    public func discardChange(_ id: UUID) {
        guard let change = state.outbox.first(where: { $0.id == id }) else { return }
        state.outbox.removeAll { $0.id == id }
        if change.operation == .create {
            own[change.memo] = nil
            state.outbox.removeAll { $0.memo == change.memo }
        }
        state.cursor = nil // refetch, so the memo returns to its server version
        didChange(own: true)
    }

    /// Adds `change` to the upload queue. The on-device library has none.
    private func queue(_ change: PendingChange) {
        guard !isOnDevice else { return }
        state.outbox.enqueue(change, inFlight: inFlight)
    }

    // MARK: Server results (used by SyncEngine)

    /// Folds in your memos from the server. A memo with queued changes keeps its local
    /// version; the conflict check happens when the change uploads.
    func receiveOwn(_ memos: [Memo]) {
        guard !memos.isEmpty else { return }
        var received: [Memo] = []
        for memo in memos where !isWaitingToSync(memo.name) {
            let stored = keepingSnippets(memo, from: own[memo.name] ?? others[memo.name])
            own[memo.name] = stored
            others[memo.name] = nil
            received.append(stored)
        }
        reflectReferences(of: received + pendingLinkSources)
        didChange(own: true, others: true, notify: false)
    }

    /// Replaces the local copy with the server's complete list, dropping memos deleted
    /// elsewhere. The server keeps no record of deletions, so this is the only way to see them.
    func replaceOwn(with memos: [Memo]) {
        let serverNames = Set(memos.map(\.name))
        for name in own.keys where !serverNames.contains(name) && !isWaitingToSync(name) {
            own[name] = nil
        }
        receiveOwn(memos)
        didChange(own: true, notify: false)
    }

    func receiveOthers(_ memos: [Memo]) {
        guard !memos.isEmpty else { return }
        var ownMemos: [Memo] = []
        for memo in memos {
            if memo.creator == user {
                ownMemos.append(memo)
            } else {
                others[memo.name] = keepingSnippets(memo, from: others[memo.name])
            }
        }
        reflectReferences(of: memos.filter { $0.creator != user } + pendingLinkSources)
        if others.count > Self.othersCacheLimit {
            let keep = others.values.sorted { $0.createdAt > $1.createdAt }.prefix(Self.othersCacheLimit)
            others = Dictionary(keep.map { ($0.name, $0) }, uniquingKeysWith: { $1 })
        }
        receiveOwn(ownMemos)
        didChange(others: true, notify: false)
    }

    /// Stores a memo fetched on its own (opening a memo, a comment's parent).
    func receive(_ memo: Memo) {
        if memo.creator == user { receiveOwn([memo]) } else { receiveOthers([memo]) }
    }

    /// The server says the memo doesn't exist: remove it now. A memo still waiting for its
    /// create to upload isn't missing, just not there yet.
    func removeMissing(_ name: String) {
        guard own[name] != nil || others[name] != nil else { return }
        guard !state.outbox.contains(where: { $0.memo == name && $0.operation == .create }) else { return }
        own[name] = nil
        others[name] = nil
        state.outbox.removeAll { $0.memo == name }
        didChange(own: true, others: true, notify: false)
    }

    /// Records a finished upload. `memo` is the server's version, when the change returned one.
    func complete(_ change: PendingChange, serverMemo memo: Memo?) {
        state.outbox.removeAll { $0.id == change.id }
        if change.operation == .delete {
            // Anything else queued for a deleted memo can't apply any more.
            state.outbox.removeAll { $0.memo == change.memo }
        }
        // A memo deleted here while its upload was running stays deleted.
        if let memo, own[memo.name] != nil {
            let stillQueued = state.outbox.contains { $0.memo == memo.name }
            if stillQueued, var local = own[memo.name] {
                local.updateTime = memo.updateTime
                local.reactions = memo.reactions
                own[memo.name] = local
                // A later text edit rebases onto the text that just uploaded, so it isn't
                // mistaken for a conflict with our own earlier edit. Only when this change sent
                // the text: otherwise the server's text may hold someone else's edit we never saw.
                if change.sentContent {
                    rebaseQueuedUpdates(of: memo)
                }
            } else {
                own[memo.name] = keepingSnippets(memo, from: own[memo.name])
            }
            if let stored = own[memo.name] { reflectReferences(of: [stored]) }
        }
        didChange(own: true, others: true, notify: false)
    }

    /// Swaps a staged attachment for the uploaded one in the memo that uses it.
    func completeUpload(_ change: PendingChange, attachment: Attachment) {
        state.outbox.removeAll { $0.id == change.id }
        if var memo = own[change.memo], let index = memo.attachments.firstIndex(where: { $0.name == attachment.name }) {
            memo.attachments[index] = attachment
            own[change.memo] = memo
        }
        try? FileManager.default.removeItem(at: location.uploadFile(for: attachment.name))
        didChange(own: true, notify: false)
    }

    func recordAttempt(_ change: PendingChange, failure: String?) {
        guard let index = state.outbox.firstIndex(where: { $0.id == change.id }) else { return }
        state.outbox[index].attempts += 1
        state.outbox[index].failure = failure
    }

    /// Text changed on both sides: the phone's version became `copy`, and `original` returns to
    /// the server's text. Both get the banner.
    func recordConflict(original: Memo, copy: Memo) {
        own[original.name] = original
        own[copy.name] = copy
        state.conflicts[original.name] = copy.name
        state.conflicts[copy.name] = original.name
        didChange(own: true, notify: false)
    }

    /// Drops links to memos the server no longer has, without queuing a change: the change being
    /// uploaded sends the memo's current links.
    func removeReferences(_ name: String, to targets: Set<String>) {
        guard var memo = own[name] else { return }
        memo.setReferences(memo.references.filter { !targets.contains($0) })
        own[name] = memo
        reflectReferences(of: [memo])
        didChange(own: true, others: true, notify: false)
    }

    // MARK: Links

    /// Your memos whose links haven't uploaded yet. A fetched memo doesn't know about them, so
    /// they win over what it says links to it.
    private var pendingLinkSources: [Memo] {
        let names = Set(state.outbox.compactMap { change -> String? in
            switch change.operation {
            case .create: change.memo
            case .update(let fields, _) where fields.contains(.relations): change.memo
            default: nil
            }
        })
        return names.compactMap { own[$0] }
    }

    private func reflectReferences(of memos: [Memo]) {
        reflectReferences(of: memos.map { ($0.name, $0.snippet, $0.references) })
    }

    /// Keeps the other end of each link in step: a memo that `sources` link to lists them under
    /// “Referenced by”, and one they stopped linking to doesn't. The server only sends those when
    /// the linked memo itself is fetched, which a change fetch won't do since it didn't change.
    private func reflectReferences(of sources: [(name: String, snippet: String, references: [String])]) {
        guard !sources.isEmpty else { return }
        let sourceNames = Set(sources.map(\.name))
        var wanted: [String: [(name: String, snippet: String)]] = [:]
        for source in sources {
            for target in source.references { wanted[target, default: []].append((source.name, source.snippet)) }
        }

        func adjusted(_ memo: Memo) -> Memo? {
            let isBacklink = { (relation: MemoRelation) in
                relation.type == .reference && relation.relatedMemo.name == memo.name && sourceNames.contains(relation.memo.name)
            }
            let want = wanted[memo.name] ?? []
            let current = memo.relations.filter(isBacklink)
            guard current.map(\.memo.name) != want.map(\.name) || zip(current, want).contains(where: { $0.memo.snippet != $1.snippet && !$1.snippet.isEmpty })
            else { return nil }
            var memo = memo
            memo.relations.removeAll(where: isBacklink)
            memo.relations += want.map { source in
                let snippet = source.snippet.isEmpty ? current.first { $0.memo.name == source.name }?.memo.snippet ?? "" : source.snippet
                return MemoRelation.reference(from: source.name, to: memo.name, sourceSnippet: snippet)
            }
            return memo
        }

        // Only memos with a link to or from a source can change.
        for (name, memo) in own where wanted[name] != nil || memo.relations.contains(where: { sourceNames.contains($0.memo.name) }) {
            if let changed = adjusted(memo) { own[name] = changed }
        }
        for (name, memo) in others where wanted[name] != nil || memo.relations.contains(where: { sourceNames.contains($0.memo.name) }) {
            if let changed = adjusted(memo) { others[name] = changed }
        }
    }

    /// The server leaves snippets out of list responses; keep the ones a single fetch brought.
    private func keepingSnippets(_ memo: Memo, from previous: Memo?) -> Memo {
        guard let previous, memo.relations.contains(where: { $0.memo.snippet.isEmpty || $0.relatedMemo.snippet.isEmpty }) else { return memo }
        var memo = memo
        for index in memo.relations.indices {
            let relation = memo.relations[index]
            guard let known = previous.relations.first(where: { $0.memo.name == relation.memo.name && $0.relatedMemo.name == relation.relatedMemo.name }) else { continue }
            if relation.memo.snippet.isEmpty { memo.relations[index].memo.snippet = known.memo.snippet }
            if relation.relatedMemo.snippet.isEmpty { memo.relations[index].relatedMemo.snippet = known.relatedMemo.snippet }
        }
        return memo
    }

    private func rebaseQueuedUpdates(of memo: Memo) {
        for index in state.outbox.indices where state.outbox[index].memo == memo.name {
            if case .update(let fields, .some) = state.outbox[index].operation {
                state.outbox[index].operation = .update(fields: fields, base: BaseVersion(updateTime: memo.updatedAt, content: memo.content))
            }
        }
    }

    /// Moves the change-fetch cursor to the newest `update_time` a pull saw. Only complete
    /// pulls move it: an upload's response is newer than edits other devices made before it.
    func advanceCursor(from memos: [Memo]) {
        guard let newest = memos.map(\.updatedAt).max() else { return }
        if state.cursor.map({ newest > $0 }) ?? true {
            state.cursor = newest
        }
    }

    // MARK: Persistence

    private func didChange(own ownChanged: Bool = false, others othersChanged: Bool = false, notify: Bool = true) {
        revision += 1
        var parts: Persisted = .state
        if ownChanged { parts.insert(.own) }
        if othersChanged { parts.insert(.others) }
        schedulePersist(parts)
        if notify { onLocalChange?() }
    }

    private func schedulePersist(_ parts: Persisted) {
        guard isLoaded else { return }
        dirty.formUnion(parts)
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.persistTask = nil
            await self.writeDirty()
        }
    }

    private func writeDirty() async {
        let parts = dirty
        dirty = []
        guard !parts.isEmpty else {
            await writing?.value
            return
        }
        // Snapshot now, on the main actor; write after the previous write finishes.
        let location = self.location
        let own = parts.contains(.own) ? Array(self.own.values) : nil
        let others = parts.contains(.others) ? Array(self.others.values) : nil
        let state = parts.contains(.state) ? self.state : nil
        let profile = parts.contains(.profile) ? self.profile : nil
        let previous = writing
        let task = Task { [weak self] in
            await previous?.value
            do {
                try await AccountArchive.write(location, own: own, others: others, state: state, profile: profile)
            } catch {
                self?.dirty.formUnion(parts)
            }
        }
        writing = task
        await task.value
    }
}

/// What a new memo is made of.
public struct MemoDraft: Sendable {
    public var content: String
    public var visibility: MemoVisibility
    public var space: String?
    public var location: MemoLocation?
    public var pinned = false
    /// Staged with ``MemoStore/stageUpload(data:filename:mimeType:)``.
    public var attachments: [Attachment] = []
    /// The memos it links to.
    public var references: [String] = []
    public var createdAt = Date.now
    /// The memo's UID, when it was picked earlier (by an extension whose upload may already
    /// have gone through). Nil picks a new one.
    public var uid: String?

    public init(content: String, visibility: MemoVisibility, space: String? = nil, location: MemoLocation? = nil, attachments: [Attachment] = [], references: [String] = []) {
        self.content = content
        self.references = references
        self.visibility = space == nil ? VisibilityRules.afterRemovingSpace(visibility) : visibility
        self.space = space
        self.location = location
        self.attachments = attachments
    }
}

/// Which memos a timeline shows.
public struct MemoQuery: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        /// Your memos.
        case mine
        /// Every creator whose memos you can read, you included.
        case everyone
        /// Only other people's memos, for search's “From others”.
        case others
    }

    public enum Order: Equatable, Sendable {
        /// Pinned first, then newest. Your own timeline.
        case pinnedThenNewest
        /// Newest first with no pinned section, as Explore does on the web.
        case newest

        func areInIncreasingOrder(_ a: Memo, _ b: Memo) -> Bool {
            if self == .pinnedThenNewest, a.pinned != b.pinned { return a.pinned }
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.name > b.name
        }
    }

    public var scope: Scope
    public var space: String?
    public var filter: MemoFilter?
    public var state: MemoState
    public var order: Order

    public init(scope: Scope, space: String? = nil, filter: MemoFilter? = nil, state: MemoState = .normal, order: Order? = nil) {
        self.scope = scope
        self.space = space
        self.filter = filter
        self.state = state
        self.order = order ?? (scope == .mine && state == .normal ? .pinnedThenNewest : .newest)
    }
}
