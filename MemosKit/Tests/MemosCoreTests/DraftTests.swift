import Foundation
import Testing
@testable import MemosCore

@MainActor
@Suite struct `Composer drafts` {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "drafts-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func attachment(_ uid: String) -> MemosCore.Attachment {
        var attachment = MemosCore.Attachment()
        attachment.name = "attachments/\(uid)"
        attachment.filename = "IMG_1.jpg"
        attachment.type = "image/jpeg"
        return attachment
    }

    @Test func `a draft survives a relaunch with everything the composer had`() {
        var location = MemoLocation()
        location.placeholder = "Kiln"
        let draft = ComposerDraft(
            text: "Glaze notes #studio", visibility: .space, space: "spaces/studio", suggestion: .protected,
            attachments: [attachment("a1")], location: location
        )
        let store = DraftStore(directory: directory)
        store.save(draft, for: .newMemo)
        store.flush()

        let relaunched = DraftStore(directory: directory)
        #expect(relaunched.hasNewMemoDraft)
        let restored = relaunched.draft(for: .newMemo)
        #expect(restored == draft)
        #expect(restored?.visibility == .space)
        #expect(restored?.suggestion == .protected)
        #expect(restored?.attachments.map(\.name) == ["attachments/a1"])
        #expect(restored?.location?.placeholder == "Kiln")
    }

    @Test func `saves are coalesced and written after a short delay`() async throws {
        let store = DraftStore(directory: directory, delay: .milliseconds(20))
        store.save(ComposerDraft(text: "a", visibility: .private), for: .newMemo)
        store.save(ComposerDraft(text: "ab", visibility: .private), for: .newMemo)
        // Reads see the latest save before it's on disk.
        #expect(store.draft(for: .newMemo)?.text == "ab")
        #expect(DraftStore(directory: directory).draft(for: .newMemo) == nil)
        #expect(store.hasNewMemoDraft)

        // A busy simulator may not schedule the delayed write within a fixed sleep.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        let relaunched = DraftStore(directory: directory)
        while relaunched.draft(for: .newMemo) == nil, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(relaunched.draft(for: .newMemo)?.text == "ab")
    }

    @Test func `edits are kept apart from the new memo and from each other`() {
        let store = DraftStore(directory: directory)
        store.save(ComposerDraft(text: "new", visibility: .private), for: .newMemo)
        store.save(ComposerDraft(text: "edit one", visibility: .private), for: .edit("memos/one"))
        store.save(ComposerDraft(text: "edit two", visibility: .private), for: .edit("memos/two"))
        store.flush()

        let relaunched = DraftStore(directory: directory)
        #expect(relaunched.draft(for: .newMemo)?.text == "new")
        #expect(relaunched.draft(for: .edit("memos/one"))?.text == "edit one")
        #expect(relaunched.draft(for: .edit("memos/two"))?.text == "edit two")
        #expect(relaunched.draft(for: .edit("memos/three")) == nil)
    }

    @Test func `removing a draft deletes it at once, even before its first write`() {
        let store = DraftStore(directory: directory)
        store.save(ComposerDraft(text: "kept", visibility: .private), for: .newMemo)
        store.flush()
        store.save(ComposerDraft(text: "newer", visibility: .private), for: .newMemo)
        store.remove(.newMemo)
        #expect(!store.hasNewMemoDraft)
        store.flush()
        #expect(store.draft(for: .newMemo) == nil)
        #expect(DraftStore(directory: directory).draft(for: .newMemo) == nil)
    }

    @Test func `signing out deletes every draft and nothing is written after`() {
        let store = DraftStore(directory: directory)
        store.save(ComposerDraft(text: "edit", visibility: .private), for: .edit("memos/one"))
        store.flush()
        store.save(ComposerDraft(text: "new", visibility: .private), for: .newMemo)
        store.removeAll()
        store.save(ComposerDraft(text: "late", visibility: .private), for: .newMemo)
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: directory.path()))
        #expect(!store.hasNewMemoDraft)
    }

    @Test func `an edit draft only applies to the version it started from`() {
        var memo = Memo()
        memo.name = "memos/one"
        memo.content = "Before"
        memo.updateTime = .init(date: Date(timeIntervalSince1970: 1_792_400_000.25))
        let draft = ComposerDraft(text: "After", visibility: .private, base: BaseVersion(updateTime: memo.updatedAt, content: memo.content))
        #expect(draft.isCurrent(for: memo))

        // Through a write and a read, as it would be after a relaunch.
        let store = DraftStore(directory: directory)
        store.save(draft, for: .edit(memo.name))
        store.flush()
        #expect(DraftStore(directory: directory).draft(for: .edit(memo.name))?.isCurrent(for: memo) == true)

        var synced = memo
        synced.updateTime = .init(date: Date(timeIntervalSince1970: 1_792_400_100))
        #expect(!draft.isCurrent(for: synced))
        var retyped = memo
        retyped.content = "Changed elsewhere"
        #expect(!draft.isCurrent(for: retyped))
        #expect(!ComposerDraft(text: "x", visibility: .private).isCurrent(for: memo))
    }
}
