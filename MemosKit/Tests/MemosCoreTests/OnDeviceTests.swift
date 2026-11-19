import Foundation
import Testing
@testable import MemosCore

@MainActor
@Suite struct `On-device library` {
    private let container = FileManager.default.temporaryDirectory.appending(path: "on-device-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var onDevice: AccountLocation { .onDevice(container: container) }
    private var server: AccountLocation {
        AccountLocation(container: container, serverURL: URL(string: "https://memos.example.com")!, user: "users/you")
    }

    private func loadedStore(_ location: AccountLocation) async -> MemoStore {
        let store = MemoStore(location: location)
        await store.load()
        return store
    }

    @Test func `lives in its own folder, apart from every server account`() {
        #expect(onDevice.isOnDevice)
        #expect(!server.isOnDevice)
        #expect(onDevice.directory != server.directory)
        #expect(!server.directory.path().hasPrefix(onDevice.directory.path()))
        #expect(!onDevice.directory.path().hasPrefix(server.directory.path()))
        #expect(!AccountLocation.hasOnDeviceLibrary(in: container))
    }

    @Test func `edits never queue an upload`() async throws {
        let store = await loadedStore(onDevice)
        var changes = 0
        store.onLocalChange = { changes += 1 }
        let photo = try store.stageUpload(data: Data([1, 2, 3]), filename: "IMG_1.jpg", mimeType: "image/jpeg")
        let memo = store.create(MemoDraft(content: "Kiln at 1240° #studio", visibility: .private, attachments: [photo]))
        store.setPinned(memo.name, true)
        store.setContent(memo.name, to: "Kiln at 1260° #studio")
        store.setArchived(memo.name, true)

        #expect(store.outbox.isEmpty)
        #expect(!store.isWaitingToSync(memo.name))
        #expect(changes == 4)
        #expect(memo.creator == AccountLocation.onDeviceUser)
        #expect(store.memo(named: memo.name)?.content == "Kiln at 1260° #studio")
        #expect(store.memo(named: memo.name)?.tags == ["studio"])
    }

    @Test func `the profile counts as loaded, so nothing waits for a server`() async {
        let store = await loadedStore(onDevice)
        #expect(store.profile.user?.name == AccountLocation.onDeviceUser)
    }

    @Test func `edits move the update time, pinning and archiving don't`() async throws {
        let store = await loadedStore(onDevice)
        var draft = MemoDraft(content: "first", visibility: .private)
        draft.createdAt = .now.addingTimeInterval(-3600)
        let memo = store.create(draft)
        store.setPinned(memo.name, true)
        store.setArchived(memo.name, true)
        #expect(store.memo(named: memo.name)?.updatedAt == memo.updatedAt)
        store.setContent(memo.name, to: "second")
        #expect(try #require(store.memo(named: memo.name)?.updatedAt) > memo.updatedAt)
    }

    @Test func `attachments stay on the device, and go with their memo`() async throws {
        let store = await loadedStore(onDevice)
        let first = try store.stageUpload(data: Data([1]), filename: "a.jpg", mimeType: "image/jpeg")
        let second = try store.stageUpload(data: Data([2]), filename: "b.jpg", mimeType: "image/jpeg")
        let memo = store.create(MemoDraft(content: "two photos", visibility: .private, attachments: [first, second]))
        #expect(store.isStaged(first) && store.isStaged(second))

        // Removing one in an edit deletes its file; nothing else holds it.
        store.update(memo.name, fields: [.attachments]) { $0.attachments = [second] }
        #expect(!store.isStaged(first))
        #expect(store.isStaged(second))

        store.delete(memo.name)
        #expect(!store.isStaged(second))
        #expect(store.memo(named: memo.name) == nil)
    }

    @Test func `survives a relaunch`() async throws {
        let store = await loadedStore(onDevice)
        let memo = store.create(MemoDraft(content: "kept", visibility: .private))
        await store.save()
        #expect(AccountLocation.hasOnDeviceLibrary(in: container))

        let relaunched = await loadedStore(onDevice)
        #expect(relaunched.memo(named: memo.name)?.content == "kept")
        #expect(relaunched.outbox.isEmpty)
    }

    @Test func `erasing one library leaves the other alone`() async throws {
        let local = await loadedStore(onDevice)
        let localMemo = local.create(MemoDraft(content: "on this iPhone", visibility: .private))
        await local.save()
        let account = await loadedStore(server)
        let serverMemo = account.create(MemoDraft(content: "on the server", visibility: .private))
        await account.save()

        // Signing out of the server erases its folder only.
        await AccountArchive.erase(server)
        #expect(await loadedStore(onDevice).memo(named: localMemo.name)?.content == "on this iPhone")

        let again = await loadedStore(server)
        let kept = again.create(MemoDraft(content: "back on the server", visibility: .private))
        await again.save()
        // Erasing the on-device library leaves the server's copy and its queue.
        await AccountArchive.erase(onDevice)
        let reloaded = await loadedStore(server)
        #expect(reloaded.memo(named: kept.name) != nil)
        #expect(reloaded.isWaitingToSync(kept.name))
        #expect(reloaded.memo(named: serverMemo.name) == nil)
        #expect(!AccountLocation.hasOnDeviceLibrary(in: container))
    }

    @Test func `a server account still queues its edits`() async {
        let store = await loadedStore(server)
        let memo = store.create(MemoDraft(content: "upload me", visibility: .private))
        #expect(store.isWaitingToSync(memo.name))
    }
}
