import Foundation
import Synchronization
import Testing
@testable import MemosCore

/// Runs against a real server: `MEMOS_TEST_SERVER=http://localhost:5230 swift test`.
/// Expects the admin from `scripts/seed_dev_server.py` (`you` / `memos-dev`), and creates a
/// fresh user per test.
private let serverURL = ProcessInfo.processInfo.environment["MEMOS_TEST_SERVER"].flatMap(URL.init(string:))

@MainActor
@Suite(.enabled(if: serverURL != nil, "Set MEMOS_TEST_SERVER to run against a server"), .serialized)
struct `Sync against a server` {
    struct Account {
        let client: MemosClient
        let store: MemoStore
        let engine: SyncEngine
        let user: String
    }

    func makeAccount() async throws -> Account {
        let admin = MemosClient(serverURL: serverURL!, credentialStore: InMemoryCredentialStore())
        _ = try await admin.detectDialect()
        _ = try await admin.signIn(username: "you", password: "memos-dev")
        let username = "t" + ResourceID.generate().lowercased().prefix(10)
        var request = Memos_Api_CreateUserRequest()
        request.user.username = username
        request.user.password = "memos-dev"
        request.user.role = .user
        request.user.state = .normal
        _ = try await admin.call(admin.users.createUser(request:headers:), request)

        let client = MemosClient(serverURL: serverURL!, credentialStore: InMemoryCredentialStore())
        _ = try await client.detectDialect()
        let user = try await client.signIn(username: username, password: "memos-dev")
        let container = FileManager.default.temporaryDirectory.appending(path: "memos-tests-\(UUID().uuidString)")
        let store = MemoStore(location: AccountLocation(container: container, serverURL: serverURL!, user: user.name))
        await store.load()
        return Account(client: client, store: store, engine: SyncEngine(client: client, store: store), user: user.name)
    }

    /// A second session for the same user, standing in for “another device”.
    func otherDevice(_ account: Account) async throws -> MemosClient {
        let client = MemosClient(serverURL: serverURL!, credentialStore: InMemoryCredentialStore())
        _ = try await client.detectDialect()
        _ = try await client.signIn(username: ResourceName.lastSegment(account.user), password: "memos-dev")
        return client
    }

    func serverMemo(_ client: MemosClient, _ name: String) async throws -> Memo {
        var request = Memos_Api_GetMemoRequest()
        request.name = name
        return try await client.call(client.memos.getMemo(request:headers:), request)
    }

    @Test func `a memo written offline uploads with the ID the app picked`() async throws {
        let account = try await makeAccount()
        account.engine.isOnline = false
        let memo = account.store.create(MemoDraft(content: "Written on a plane #travel", visibility: .private))
        #expect(account.store.isWaitingToSync(memo.name))
        #expect(account.store.memos(MemoQuery(scope: .mine, filter: try MemoFilter(#"tag in ["travel"]"#))).count == 1)

        account.engine.isOnline = true
        await account.engine.sync()
        #expect(account.store.outbox.isEmpty)
        let uploaded = try await serverMemo(account.client, memo.name)
        #expect(uploaded.content == "Written on a plane #travel")
        #expect(uploaded.tags == ["travel"])
        #expect(account.store.own[memo.name]?.updatedAt == uploaded.updatedAt)
    }

    @Test func `pinning and archiving offline apply after the create`() async throws {
        let account = try await makeAccount()
        account.engine.isOnline = false
        let memo = account.store.create(MemoDraft(content: "Pin me", visibility: .private))
        account.store.setPinned(memo.name, true)
        let archived = account.store.create(MemoDraft(content: "Archive me", visibility: .private))
        account.store.setArchived(archived.name, true)
        account.engine.isOnline = true
        await account.engine.sync()
        #expect(account.store.outbox.isEmpty)
        #expect(try await serverMemo(account.client, memo.name).pinned)
        #expect(try await serverMemo(account.client, archived.name).state == .archived)
        #expect(account.store.memos(MemoQuery(scope: .mine, state: .archived)).map(\.name) == [archived.name])
    }

    @Test func `edits made elsewhere arrive with the next change fetch`() async throws {
        let account = try await makeAccount()
        let memo = account.store.create(MemoDraft(content: "v1", visibility: .private))
        await account.engine.sync()

        let other = try await otherDevice(account)
        var update = Memos_Api_UpdateMemoRequest()
        update.memo.name = memo.name
        update.memo.content = "v2 from the web"
        update.updateMask.paths = ["content"]
        _ = try await other.call(other.memos.updateMemo(request:headers:), update)

        var create = Memos_Api_CreateMemoRequest()
        create.memo.content = "Written on the web"
        create.memo.visibility = .private
        let webMemo = try await other.call(other.memos.createMemo(request:headers:), create)

        // The server stores seconds; make sure the cursor window has to do its job.
        try await Task.sleep(for: .seconds(1.1))
        await account.engine.sync()
        #expect(account.store.own[memo.name]?.content == "v2 from the web")
        #expect(account.store.own[webMemo.name] != nil)
    }

    @Test func `text changed on both sides is saved as a separate memo`() async throws {
        let account = try await makeAccount()
        let memo = account.store.create(MemoDraft(content: "Groceries: milk", visibility: .private))
        await account.engine.sync()

        let other = try await otherDevice(account)
        var update = Memos_Api_UpdateMemoRequest()
        update.memo.name = memo.name
        update.memo.content = "Groceries: milk, eggs"
        update.updateMask.paths = ["content"]
        try await Task.sleep(for: .seconds(1.1))
        _ = try await other.call(other.memos.updateMemo(request:headers:), update)

        account.engine.isOnline = false
        account.store.setContent(memo.name, to: "Groceries: milk, bread")
        account.store.setPinned(memo.name, true)
        account.engine.isOnline = true
        await account.engine.sync()

        #expect(account.store.outbox.isEmpty)
        let original = try await serverMemo(account.client, memo.name)
        #expect(original.content == "Groceries: milk, eggs")
        #expect(original.pinned, "non-text fields from the same edit still apply")
        let copyName = try #require(account.store.conflictCounterpart(of: memo.name))
        #expect(account.store.conflictCounterpart(of: copyName) == memo.name)
        let copy = try await serverMemo(account.client, copyName)
        #expect(copy.content == "Groceries: milk, bread")
        #expect(copy.relations.contains { $0.relatedMemo.name == memo.name && $0.type == .reference })
        #expect(account.store.own[memo.name]?.content == "Groceries: milk, eggs")
    }

    @Test func `two edits in a row are not a conflict with yourself`() async throws {
        let account = try await makeAccount()
        let memo = account.store.create(MemoDraft(content: "a", visibility: .private))
        await account.engine.sync()
        account.store.setContent(memo.name, to: "ab")
        await account.engine.push()
        try await Task.sleep(for: .seconds(1.1))
        account.store.setContent(memo.name, to: "abc")
        await account.engine.push()
        #expect(account.store.conflictCounterpart(of: memo.name) == nil)
        #expect(try await serverMemo(account.client, memo.name).content == "abc")
    }

    @Test func `memos deleted elsewhere disappear on the full comparison`() async throws {
        let account = try await makeAccount()
        let kept = account.store.create(MemoDraft(content: "keep", visibility: .private))
        let doomed = account.store.create(MemoDraft(content: "delete me elsewhere", visibility: .private))
        await account.engine.sync()

        let other = try await otherDevice(account)
        var delete = Memos_Api_DeleteMemoRequest()
        delete.name = doomed.name
        _ = try await other.call(other.memos.deleteMemo(request:headers:), delete)

        await account.engine.sync()
        #expect(account.store.own[doomed.name] != nil, "a change fetch can't see deletions")
        await account.engine.sync(fullCompare: true)
        #expect(account.store.own[doomed.name] == nil)
        #expect(account.store.own[kept.name] != nil)
    }

    @Test func `attachments upload before the memo that uses them`() async throws {
        let account = try await makeAccount()
        account.engine.isOnline = false
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        let attachment = try account.store.stageUpload(data: bytes, filename: "sample.bin", mimeType: "application/octet-stream")
        let memo = account.store.create(MemoDraft(content: "With a file", visibility: .private, attachments: [attachment]))
        #expect(account.store.outbox.map(\.operation) == [.uploadAttachment(attachment: attachment.name), .create])

        account.engine.isOnline = true
        await account.engine.sync()
        #expect(account.store.outbox.isEmpty)
        let uploaded = try await serverMemo(account.client, memo.name)
        #expect(uploaded.attachments.map(\.name) == [attachment.name])
        #expect(uploaded.attachments.first?.size == Int64(bytes.count))
        #expect(!account.store.isStaged(attachment))
    }

    @Test func `a create whose response was lost is not uploaded twice`() async throws {
        let account = try await makeAccount()
        account.engine.isOnline = false
        let attachment = try account.store.stageUpload(data: Data(repeating: 1, count: 1000), filename: "a.bin", mimeType: "application/octet-stream")
        let memo = account.store.create(MemoDraft(content: "Lost response", visibility: .private, attachments: [attachment]))

        // Another process uploads the same memo first, as if the app's own request had gone
        // through but its response never arrived.
        let file = try Data(contentsOf: account.store.location.uploadFile(for: attachment.name))
        let draft = ExtensionDraft(uid: memo.uid, content: "Lost response", visibility: .private, files: [.init(filename: "a.bin", mimeType: "application/octet-stream", storedName: "a")])
        _ = try await AttachmentUpload.upload(file, filename: "a.bin", mimeType: "application/octet-stream", attachmentID: ResourceName.lastSegment(attachment.name), client: account.client)
        var create = Memos_Api_CreateMemoRequest()
        create.memo.content = draft.content
        create.memo.visibility = .private
        var reference = Attachment()
        reference.name = attachment.name
        create.memo.attachments = [reference]
        create.memoID = memo.uid
        _ = try await account.client.call(account.client.memos.createMemo(request:headers:), create)

        account.engine.isOnline = true
        await account.engine.sync()
        #expect(account.store.outbox.isEmpty, "\(account.store.outbox.map(\.failure))")
        let mine = try await account.client.call(account.client.memos.listMemos(request:headers:), Memos_Api_ListMemosRequest())
        #expect(mine.memos.filter { $0.content == "Lost response" }.count == 1)
    }

    @Test func `deleting offline removes the memo on the server`() async throws {
        let account = try await makeAccount()
        let memo = account.store.create(MemoDraft(content: "bye", visibility: .private))
        await account.engine.sync()
        account.engine.isOnline = false
        account.store.delete(memo.name)
        account.engine.isOnline = true
        await account.engine.sync()
        await #expect(throws: APIError.self) { try await serverMemo(account.client, memo.name) }
    }

    @Test func `an expired access token is refreshed through the cookie`() async throws {
        let account = try await makeAccount()
        let credentialStore = InMemoryCredentialStore()
        var credentials = try #require(await account.client.credentials)
        credentials.accessToken = "expired"
        credentials.accessTokenExpiry = .distantPast
        credentialStore.save(credentials)
        let client = MemosClient(serverURL: serverURL!, credentialStore: credentialStore)
        let response = try await client.call(client.auth.getCurrentUser(request:headers:), Memos_Api_GetCurrentUserRequest())
        #expect(response.user.name == account.user)
        let refreshed = try #require(credentialStore.load())
        #expect(refreshed.accessToken != "expired")
        #expect(refreshed.refreshToken != credentials.refreshToken, "the refresh token rotates")
    }

    @Test func `an access token signs in until it is revoked`() async throws {
        let account = try await makeAccount()
        var create = Memos_Api_CreatePersonalAccessTokenRequest()
        create.parent = account.user
        create.description_p = "tests"
        let created = try await account.client.call(account.client.users.createPersonalAccessToken(request:headers:), create)

        let expired = Mutex(false)
        let credentialStore = InMemoryCredentialStore()
        let client = MemosClient(serverURL: serverURL!, credentialStore: credentialStore) { expired.withLock { $0 = true } }
        _ = try await client.detectDialect()
        let user = try await client.signIn(accessToken: " \(created.token)\n")
        #expect(user.name == account.user)
        _ = try await client.call(client.memos.listMemos(request:headers:), Memos_Api_ListMemosRequest())
        #expect(credentialStore.load()?.refreshToken == nil)

        var delete = Memos_Api_DeletePersonalAccessTokenRequest()
        delete.name = created.personalAccessToken.name
        _ = try await account.client.call(account.client.users.deletePersonalAccessToken(request:headers:), delete)
        await #expect(throws: APIError.self) {
            _ = try await client.call(client.memos.listMemos(request:headers:), Memos_Api_ListMemosRequest())
        }
        #expect(expired.withLock { $0 }, "a revoked token ends the session")
        #expect(credentialStore.load() == nil)

        let stranger = MemosClient(serverURL: serverURL!, credentialStore: InMemoryCredentialStore())
        _ = try await stranger.detectDialect()
        await #expect(throws: APIError.self) { _ = try await stranger.signIn(accessToken: "memos_pat_notatoken") }
    }

    @Test func `the profile records Spaces, views and whether others share`() async throws {
        let account = try await makeAccount()
        var create = Memos_Api_CreateSpaceRequest()
        create.space.title = "Garden"
        _ = try await account.client.call(account.client.spaces.createSpace(request:headers:), create)
        await account.engine.refreshProfile()
        #expect(account.store.profile.spaces.map(\.title) == ["Garden"])
        #expect(account.store.profile.user?.name == account.user)
        #expect(account.store.profile.defaultVisibility == nil || account.store.profile.defaultVisibility == "PRIVATE")
    }

    @Test func `an extension's upload can be repeated without a duplicate`() async throws {
        let account = try await makeAccount()
        let draft = ExtensionDraft(content: "Shared from Safari https://usememos.com", visibility: .private, files: [
            .init(filename: "page.png", mimeType: "image/png", storedName: "page.png"),
        ])
        let files = ["page.png": Data(repeating: 7, count: 2048)]
        let first = try await AttachmentUpload.create(draft, files: files, client: account.client)
        let again = try await AttachmentUpload.create(draft, files: files, client: account.client)
        #expect(first.name == again.name)
        #expect(first.name == "memos/\(draft.uid)")
        #expect(first.attachments.count == 1)
        await account.engine.sync()
        #expect(account.store.own[first.name]?.content == draft.content)
    }

    // Regressions from review.

    @Test func `opening a memo that hasn't uploaded yet doesn't delete it`() async throws {
        let account = try await makeAccount()
        account.engine.isOnline = false
        let memo = account.store.create(MemoDraft(content: "Not uploaded yet", visibility: .private))
        account.engine.isOnline = true
        account.engine.scheduleUpload(after: .seconds(60)) // keep the queue from running first
        await #expect(throws: APIError.self) { try await account.engine.refresh(memo.name) }
        #expect(account.store.own[memo.name] != nil)
        #expect(account.store.isWaitingToSync(memo.name))
    }

    @Test func `a photo added after a text edit reaches the server`() async throws {
        let account = try await makeAccount()
        let memo = account.store.create(MemoDraft(content: "v1", visibility: .private))
        await account.engine.sync()
        account.engine.isOnline = false
        account.store.setContent(memo.name, to: "v2")
        let photo = try account.store.stageUpload(data: Data(repeating: 9, count: 500), filename: "p.jpg", mimeType: "image/jpeg")
        account.store.update(memo.name, fields: [.attachments]) { $0.attachments.append(photo) }
        account.engine.isOnline = true
        await account.engine.sync()
        #expect(account.store.outbox.isEmpty)
        let server = try await serverMemo(account.client, memo.name)
        #expect(server.content == "v2")
        #expect(server.attachments.map(\.name) == [photo.name])
    }

    @Test func `uploading an edit doesn't skip another device's earlier edit`() async throws {
        let account = try await makeAccount()
        let x = account.store.create(MemoDraft(content: "x1", visibility: .private))
        let y = account.store.create(MemoDraft(content: "y1", visibility: .private))
        await account.engine.sync()

        try await Task.sleep(for: .seconds(1.1))
        let other = try await otherDevice(account)
        var update = Memos_Api_UpdateMemoRequest()
        update.memo.name = x.name
        update.memo.content = "x2 from the web"
        update.updateMask.paths = ["content", "update_time"]
        _ = try await other.call(other.memos.updateMemo(request:headers:), update)

        try await Task.sleep(for: .seconds(2.1))
        account.store.setContent(y.name, to: "y2")
        await account.engine.push()
        await account.engine.sync()
        #expect(account.store.own[x.name]?.content == "x2 from the web")
    }

    @Test func `a memo deleted while its upload runs stays deleted`() async throws {
        let account = try await makeAccount()
        account.engine.isOnline = false
        let memo = account.store.create(MemoDraft(content: "Deleted mid-upload", visibility: .private))
        let create = try #require(account.store.outbox.first)
        account.store.inFlight = create.id
        account.store.delete(memo.name)
        account.store.inFlight = nil
        account.store.complete(create, serverMemo: memo)
        #expect(account.store.own[memo.name] == nil)
        #expect(account.store.outbox.map(\.operation) == [.delete])
    }

    @Test func `pull to refresh during a push still compares the full list`() async throws {
        let account = try await makeAccount()
        let doomed = account.store.create(MemoDraft(content: "deleted on the web", visibility: .private))
        await account.engine.sync()
        let other = try await otherDevice(account)
        var delete = Memos_Api_DeleteMemoRequest()
        delete.name = doomed.name
        _ = try await other.call(other.memos.deleteMemo(request:headers:), delete)

        account.store.create(MemoDraft(content: "busy", visibility: .private))
        async let pushing: Void = account.engine.push()
        async let refreshing: Void = account.engine.sync(fullCompare: true)
        _ = await (pushing, refreshing)
        #expect(account.store.own[doomed.name] == nil)
    }

    @Test func `the local copy survives a relaunch`() async throws {
        let account = try await makeAccount()
        account.engine.isOnline = false
        let memo = account.store.create(MemoDraft(content: "persist me", visibility: .private))
        await account.store.save()
        let reopened = MemoStore(location: account.store.location)
        await reopened.load()
        #expect(reopened.own[memo.name]?.content == "persist me")
        #expect(reopened.isWaitingToSync(memo.name))
    }
}
