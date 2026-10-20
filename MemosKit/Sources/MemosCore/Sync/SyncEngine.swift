import Connect
import Foundation
import Observation
import SwiftProtobuf
import os

/// Moves changes between ``MemoStore`` and the server.
///
/// - Uploads queued changes in the order they were made, attachments before the memo that uses
///   them. A connectivity failure stops the queue until the next sync.
/// - Fetches your memos changed since the last sync (`updated_ts >= cursor - 1s`).
/// - Once a day on Wi-Fi, and on pull-to-refresh, compares the full list to find memos deleted
///   elsewhere, because the server keeps no record of deletions.
/// - Before uploading an edit to the text, fetches the memo and compares it with the version the
///   edit started from. If the text changed on both sides, the phone's version is saved as a new
///   memo that references the original.
@MainActor
@Observable
public final class SyncEngine {
    public let client: MemosClient
    public let store: MemoStore

    public private(set) var isSyncing = false
    /// The last failure that wasn't about connectivity, for a quiet error in Settings.
    public private(set) var lastError: APIError?
    /// Set from the network path monitor. Offline, nothing is attempted.
    public var isOnline = true {
        didSet {
            if isOnline && !oldValue {
                retryDelay = .seconds(15)
                scheduleUpload(after: .zero)
            }
        }
    }
    /// Whether the current network is cellular or otherwise expensive. The daily full
    /// comparison waits for Wi-Fi.
    public var isExpensiveNetwork = false

    @ObservationIgnored private var wantsPush = false
    @ObservationIgnored private var wantsPull = false
    @ObservationIgnored private var wantsFullCompare = false
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: Duration = .seconds(15)
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "app.memos", category: "sync")

    static let pageSize: Int32 = 1000

    public init(client: MemosClient, store: MemoStore) {
        self.client = client
        self.store = store
        store.onLocalChange = { [weak self] in self?.scheduleUpload() }
    }

    private var me: String { store.user }

    // MARK: Entry points

    /// Uploads soon after a local change, coalescing quick successive edits. A push already
    /// running is never cancelled; it picks the new change up instead.
    public func scheduleUpload(after delay: Duration = .milliseconds(500)) {
        if running != nil {
            wantsPush = true
            return
        }
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            await self.push()
        }
    }

    /// Pushes queued changes, then pulls the server's. Runs on launch, on foreground and on
    /// pull-to-refresh (`fullCompare: true`). If a sync is already running, this one is folded
    /// into it, and returns when it's done.
    public func sync(fullCompare: Bool = false) async {
        wantsPush = true
        wantsPull = true
        if fullCompare { wantsFullCompare = true }
        await run()
    }

    /// Uploads the queue without pulling.
    public func push() async {
        wantsPush = true
        await run()
    }

    private func run() async {
        guard isOnline else { return }
        if let running {
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            self.isSyncing = true
            defer {
                self.isSyncing = false
                self.running = nil
            }
            while self.isOnline && (self.wantsPush || self.wantsPull) {
                let pull = self.wantsPull
                let fullCompare = self.wantsFullCompare || self.dailyCompareDue
                self.wantsPush = false
                self.wantsPull = false
                self.wantsFullCompare = false
                await self.pushQueue()
                guard pull, self.isOnline else { continue }
                do throws(APIError) {
                    try await self.pull(fullCompare: fullCompare)
                    self.lastError = nil
                } catch {
                    if fullCompare { self.wantsFullCompare = true }
                    self.handle(error)
                }
                await self.refreshProfile()
            }
        }
        running = task
        await task.value
    }

    /// Tries again later, backing off from 15 seconds to 5 minutes, rather than waiting for the
    /// next launch: after the server didn't answer (`offline`), or answered with an error that
    /// may pass.
    private func scheduleRetry(offline: Bool) {
        if offline { isOnline = false }
        guard retryTask == nil else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(300))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.isOnline = true
            await self.sync()
        }
    }

    private var dailyCompareDue: Bool {
        guard !isExpensiveNetwork else { return false }
        guard let last = store.state.lastFullCompareAt else { return true }
        return Date.now.timeIntervalSince(last) > 24 * 60 * 60
    }

    private func handle(_ error: APIError) {
        if error.isConnectivity {
            scheduleRetry(offline: true)
        } else if !error.isSessionExpired {
            lastError = error
            logger.error("Sync failed: \(error.description, privacy: .public)")
        }
    }

    // MARK: Upload

    private func nextChange() -> PendingChange? {
        var blocked: Set<String> = []
        for change in store.state.outbox {
            // A delete never waits: it makes everything before it moot.
            if change.operation == .delete && change.failure == nil { return change }
            if change.failure != nil || blocked.contains(change.memo) {
                // Later changes to the same memo wait behind a failed one.
                blocked.insert(change.memo)
                continue
            }
            return change
        }
        return nil
    }

    private func pushQueue() async {
        while isOnline, let change = nextChange() {
            store.inFlight = change.id
            do {
                try await upload(change)
                store.inFlight = nil
                retryDelay = .seconds(15)
            } catch {
                store.inFlight = nil
                if error.isConnectivity || error.isSessionExpired {
                    handle(error)
                    return
                }
                let permanent: Set<Code> = [.invalidArgument, .permissionDenied, .failedPrecondition, .resourceExhausted, .outOfRange]
                let attempts = change.attempts + 1
                if permanent.contains(error.code) || attempts >= 5 {
                    store.recordAttempt(change, failure: error.description)
                    logger.error("Upload rejected: \(error.description, privacy: .public)")
                } else {
                    store.recordAttempt(change, failure: nil)
                    lastError = error
                    scheduleRetry(offline: false)
                    return
                }
            }
        }
    }

    private func upload(_ change: PendingChange) async throws(APIError) {
        switch change.operation {
        case .uploadAttachment(let attachment):
            try await uploadAttachment(change, attachment: attachment)
        case .create:
            try await uploadCreate(change)
        case .update(let fields, let base):
            try await uploadUpdate(change, fields: fields, base: base)
        case .delete:
            var request = Memos_Api_DeleteMemoRequest()
            request.name = change.memo
            do {
                _ = try await client.call(client.memos.deleteMemo(request:headers:), request)
            } catch where error.code == .notFound {
                // Already gone.
            }
            store.complete(change, serverMemo: nil)
        }
    }

    private func uploadCreate(_ change: PendingChange) async throws(APIError) {
        guard let local = store.own[change.memo] else {
            store.complete(change, serverMemo: nil)
            return
        }
        var memo = Memo()
        memo.content = local.content
        memo.visibility = local.visibility
        memo.state = .normal
        memo.spaceName = local.spaceName
        if let location = local.locationIfSet { memo.location = location }
        memo.attachments = local.attachments.filter { !store.isStaged($0) }.map(Self.reference)
        memo.createTime = local.createTime
        var request = Memos_Api_CreateMemoRequest()
        request.memo = memo
        request.memoID = local.uid

        var created: Memo
        do {
            created = try await client.call(client.memos.createMemo(request:headers:), request)
        } catch where !error.isConnectivity && !error.isSessionExpired {
            // The earlier attempt went through. The server says so with ALREADY_EXISTS, or, when
            // the memo has attachments, by refusing to bind them twice; either way it's there.
            guard let existing = try? await fetch(change.memo) else { throw error }
            created = existing
        }

        // Pinning and archiving aren't part of a create.
        var followUp: [String] = []
        if local.pinned != created.pinned { followUp.append("pinned") }
        if local.state != created.state { followUp.append("state") }
        if !followUp.isEmpty {
            var update = Memos_Api_UpdateMemoRequest()
            update.memo.name = created.name
            update.memo.pinned = local.pinned
            update.memo.state = local.state
            update.updateMask.paths = followUp
            created = try await client.call(client.memos.updateMemo(request:headers:), update)
        }
        store.complete(change, serverMemo: created)
    }

    private func uploadUpdate(_ change: PendingChange, fields: Set<MemoField>, base: BaseVersion?) async throws(APIError) {
        guard let local = store.own[change.memo] else {
            store.complete(change, serverMemo: nil)
            return
        }

        if fields.contains(.content), let base {
            let remote: Memo
            do {
                remote = try await fetch(change.memo)
            } catch where error.code == .notFound {
                store.removeMissing(change.memo)
                return
            }
            // The server only moves `update_time` when a client asks it to (the web does), so
            // the text is compared directly: if it differs from the version the edit started
            // from, someone else changed it.
            let changedElsewhere = remote.content != base.content
            if changedElsewhere && remote.content != local.content {
                try await splitConflict(change, local: local, remote: remote, otherFields: fields.subtracting([.content]))
                return
            }
        }

        let request = updateRequest(local, fields: fields)
        do {
            let updated = try await client.call(client.memos.updateMemo(request:headers:), request)
            store.complete(change, serverMemo: updated)
        } catch where error.code == .notFound {
            store.removeMissing(change.memo)
        }
    }

    /// Saves the phone's text as a new memo that references the original, and returns the
    /// original to the server's text. Non-text fields from the same change still apply to the
    /// original: the last one wins.
    private func splitConflict(_ change: PendingChange, local: Memo, remote: Memo, otherFields: Set<MemoField>) async throws(APIError) {
        var copy = Memo()
        copy.content = local.content
        copy.visibility = local.visibility
        copy.state = .normal
        copy.spaceName = local.spaceName
        // The copy's ID comes from the change, so a retry finds the copy instead of making another.
        let copyID = change.id.uuidString.lowercased()
        var create = Memos_Api_CreateMemoRequest()
        create.memo = copy
        create.memoID = copyID
        let saved: Memo
        do {
            saved = try await client.call(client.memos.createMemo(request:headers:), create)
        } catch where !error.isConnectivity && !error.isSessionExpired {
            guard let existing = try? await fetch("memos/\(copyID)") else { throw error }
            saved = existing
        }

        var relation = Memos_Api_MemoRelation()
        relation.memo.name = saved.name
        relation.relatedMemo.name = remote.name
        relation.type = .reference
        var relations = Memos_Api_SetMemoRelationsRequest()
        relations.name = saved.name
        relations.relations = [relation]
        _ = try? await client.call(client.memos.setMemoRelations(request:headers:), relations)

        var original = remote
        if !otherFields.isEmpty {
            var request = updateRequest(local, fields: otherFields)
            request.memo.content = remote.content
            original = try await client.call(client.memos.updateMemo(request:headers:), request)
        }
        store.complete(change, serverMemo: nil)
        store.recordConflict(original: original, copy: (try? await fetch(saved.name)) ?? saved)
    }

    private func uploadAttachment(_ change: PendingChange, attachment name: String) async throws(APIError) {
        let file = store.location.uploadFile(for: name)
        guard let data = try? Data(contentsOf: file) else {
            // The file is gone; drop it from the memo rather than block the queue.
            store.update(change.memo, fields: [.attachments]) { $0.attachments.removeAll { $0.name == name } }
            store.complete(change, serverMemo: nil)
            return
        }
        guard let placeholder = store.own[change.memo]?.attachments.first(where: { $0.name == name }) else {
            store.complete(change, serverMemo: nil)
            return
        }

        let uploaded = try await AttachmentUpload.upload(
            data,
            filename: placeholder.filename,
            mimeType: placeholder.type,
            attachmentID: ResourceName.lastSegment(name),
            client: client
        )
        store.completeUpload(change, attachment: uploaded)
    }

    /// An update for `fields` of `memo`. Like the web, a change to the text, attachments or
    /// location also asks the server to stamp `update_time`, which is what lets other devices'
    /// change fetches see it. Pinning, archiving and audience changes leave it alone.
    private func updateRequest(_ memo: Memo, fields: Set<MemoField>) -> Memos_Api_UpdateMemoRequest {
        var request = Memos_Api_UpdateMemoRequest()
        request.memo = memo
        request.memo.clearUpdateTime()
        request.memo.attachments = memo.attachments.filter { !store.isStaged($0) }.map(Self.reference)
        var paths = fields.map(\.rawValue).sorted()
        if !fields.isDisjoint(with: [.content, .attachments, .location]) {
            paths.append("update_time")
        }
        request.updateMask.paths = paths
        return request
    }

    private static func reference(_ attachment: Attachment) -> Attachment {
        var reference = Attachment()
        reference.name = attachment.name
        return reference
    }

    // MARK: Download

    private func pull(fullCompare: Bool) async throws(APIError) {
        let mine = "creator == \(CELString.quote(me))"
        if fullCompare || store.state.cursor == nil {
            var all: [Memo] = []
            for state in [MemoState.normal, .archived] {
                all += try await fetchAll(filter: mine, state: state, orderBy: nil)
            }
            store.replaceOwn(with: all)
            store.advanceCursor(from: all)
            store.state.lastFullCompareAt = .now
        } else if let cursor = store.state.cursor {
            let since = CELString.quote(CELString.timestamp(cursor.addingTimeInterval(-1)))
            let filter = "\(mine) && updated_ts >= timestamp(\(since))"
            var changed: [Memo] = []
            for state in [MemoState.normal, .archived] {
                changed += try await fetchAll(filter: filter, state: state, orderBy: "update_time asc")
            }
            // Only once both fetches succeeded, so a failure can't skip a window of changes.
            store.receiveOwn(changed)
            store.advanceCursor(from: changed)
        }
        store.state.lastSyncAt = .now
    }

    private func fetchAll(filter: String, state: MemoState, orderBy: String?) async throws(APIError) -> [Memo] {
        var memos: [Memo] = []
        var token = ""
        repeat {
            var request = Memos_Api_ListMemosRequest()
            request.filter = filter
            request.state = state
            request.pageSize = Self.pageSize
            request.pageToken = token
            if let orderBy { request.orderBy = orderBy }
            let sent = request
            let response = try await client.call(client.memos.listMemos(request:headers:), sent)
            memos += response.memos
            token = response.nextPageToken
        } while !token.isEmpty
        return memos
    }

    /// One page of the memos anyone can show you, for the Everyone timeline and search. Other
    /// people's memos are cached as they arrive, so they can be read offline later.
    public func fetchPage(filter: String?, pageToken: String = "", pageSize: Int32 = 50) async throws(APIError) -> (memos: [Memo], nextPageToken: String) {
        var request = Memos_Api_ListMemosRequest()
        if let filter { request.filter = filter }
        request.pageToken = pageToken
        request.pageSize = pageSize
        request.orderBy = "create_time desc"
        let sent = request
        do {
            let response = try await client.call(client.memos.listMemos(request:headers:), sent)
            store.receiveOthers(response.memos)
            store.state.othersFetchedAt = .now
            return (response.memos, response.nextPageToken)
        } catch {
            handle(error)
            throw error
        }
    }

    /// Fetches one memo and stores it. A memo the server no longer has is removed immediately.
    @discardableResult
    public func refresh(_ name: String) async throws(APIError) -> Memo {
        do {
            let memo = try await fetch(name)
            store.receive(memo)
            return memo
        } catch where error.code == .notFound || error.code == .permissionDenied {
            store.removeMissing(name)
            throw error
        }
    }

    private func fetch(_ name: String) async throws(APIError) -> Memo {
        var request = Memos_Api_GetMemoRequest()
        request.name = name
        return try await client.call(client.memos.getMemo(request:headers:), request)
    }

    // MARK: Profile

    /// Refreshes everything besides memos the app keeps offline: the user, default
    /// visibility, Spaces, saved views, whether anyone else's memos are readable, the
    /// instance's reactions and the unread count.
    public func refreshProfile() async {
        let me = self.me
        let client = self.client
        var profile = store.profile

        if let response = try? await client.call(client.auth.getCurrentUser(request:headers:), Memos_Api_GetCurrentUserRequest()) {
            profile.user = response.user
        }

        var settingRequest = Memos_Api_GetUserSettingRequest()
        settingRequest.name = "\(me)/settings/GENERAL"
        if let setting = try? await client.call(client.users.getUserSetting(request:headers:), settingRequest) {
            let value = setting.generalSetting.memoVisibility
            profile.defaultVisibility = value.isEmpty ? nil : value
        }

        var tagsRequest = Memos_Api_GetUserSettingRequest()
        tagsRequest.name = "\(me)/settings/TAGS"
        if let setting = try? await client.call(client.users.getUserSetting(request:headers:), tagsRequest) {
            profile.tagBlur = TagBlurRules(setting.tagsSetting)
        }

        var spaces: [Space] = []
        var spacesToken = ""
        repeat {
            var request = Memos_Api_ListSpacesRequest()
            request.pageSize = 100
            request.pageToken = spacesToken
            let sent = request
            guard let response = try? await client.call(client.spaces.listSpaces(request:headers:), sent) else { break }
            spaces += response.spaces
            spacesToken = response.nextPageToken
            if spacesToken.isEmpty { profile.spaces = spaces.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
        } while !spacesToken.isEmpty

        var viewsRequest = Memos_Api_ListMemoViewsRequest()
        viewsRequest.parent = me
        if let response = try? await client.call(client.users.listMemoViews(request:headers:), viewsRequest) {
            profile.views = response.memoViews
        }

        // One entry per creator with at least one memo you can read. If the only entry is you,
        // the Mine / Everyone toggle stays hidden.
        var statsRequest = Memos_Api_ListUserStatsRequest()
        statsRequest.parent = "users/-"
        if let response = try? await client.call(client.users.listUserStats(request:headers:), statsRequest) {
            profile.hasOtherCreators = response.userStats.contains { $0.name != "\(me)/stats" && $0.totalMemoCount > 0 }
            if let mine = response.userStats.first(where: { $0.name == "\(me)/stats" }) {
                profile.tagCounts = mine.tagCounts.mapValues(Int.init)
            }
        }

        if let instance = try? await client.callPublic(client.instance.getInstanceProfile(request:headers:), Memos_Api_GetInstanceProfileRequest()) {
            profile.instance = instance
        }
        var reactionsRequest = Memos_Api_GetInstanceSettingRequest()
        reactionsRequest.name = "instance/settings/MEMO_RELATED"
        if let setting = try? await client.call(client.instance.getInstanceSetting(request:headers:), reactionsRequest) {
            profile.reactions = setting.memoRelatedSetting.reactions
        }

        var inboxRequest = Memos_Api_ListUserNotificationsRequest()
        inboxRequest.parent = me
        if let response = try? await client.call(client.users.listUserNotifications(request:headers:), inboxRequest) {
            profile.unreadNotifications = response.notifications.count { $0.status == .unread }
        }

        store.profile = profile
    }
}
