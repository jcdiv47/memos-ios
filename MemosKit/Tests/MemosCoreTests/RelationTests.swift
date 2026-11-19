import Foundation
import Testing
@testable import MemosAPI
@testable import MemosCore

@MainActor
@Suite struct `Memo links` {
    private func makeStore() async -> MemoStore {
        let container = FileManager.default.temporaryDirectory.appending(path: "links-\(UUID().uuidString)")
        let location = AccountLocation(container: container, serverURL: URL(string: "https://memos.example.com")!, user: "users/you")
        let store = MemoStore(location: location)
        await store.load()
        return store
    }

    @Test func `references and backlinks read the right direction of relations`() {
        var memo = Memo()
        memo.name = "memos/a"
        memo.relations = [
            .reference(from: "memos/a", to: "memos/b"),
            .reference(from: "memos/c", to: "memos/a", sourceSnippet: "From C"),
            .reference(from: "memos/a", to: "memos/b"),
        ]
        #expect(memo.references == ["memos/b"])
        #expect(memo.referencedBy == ["memos/c"])
        #expect(memo.relationSnippet(for: "memos/c") == "From C")
    }

    @Test func `setting references keeps backlinks and known snippets`() {
        var memo = Memo()
        memo.name = "memos/a"
        var known = MemoRelation.reference(from: "memos/a", to: "memos/b")
        known.relatedMemo.snippet = "B"
        memo.relations = [known, .reference(from: "memos/c", to: "memos/a")]

        memo.setReferences(["memos/b", "memos/d", "memos/a"])
        #expect(memo.references == ["memos/b", "memos/d"])
        #expect(memo.referencedBy == ["memos/c"])
        #expect(memo.relationSnippet(for: "memos/b") == "B")
        #expect(memo.referenceRelations.allSatisfy { $0.relatedMemo.snippet.isEmpty })
    }

    @Test func `linking a memo shows the link on both memos and queues it`() async throws {
        let store = await makeStore()
        let target = store.create(MemoDraft(content: "Target", visibility: .private))
        let source = store.create(MemoDraft(content: "Source", visibility: .private, references: [target.name]))

        #expect(store.own[source.name]?.references == [target.name])
        #expect(store.own[target.name]?.referencedBy == [source.name])
        #expect(store.own[target.name]?.relationSnippet(for: source.name) == "Source")

        store.update(source.name, fields: [.relations]) { $0.setReferences([]) }
        #expect(store.own[target.name]?.referencedBy == [])
    }

    @Test func `deleting a memo removes its backlinks`() async throws {
        let store = await makeStore()
        let target = store.create(MemoDraft(content: "Target", visibility: .private))
        let source = store.create(MemoDraft(content: "Source", visibility: .private, references: [target.name]))
        store.delete(source.name)
        #expect(store.own[target.name]?.referencedBy == [])
    }

    @Test func `a link fetched from the server reaches a memo the fetch didn't include`() async throws {
        let store = await makeStore()
        var target = Memo()
        target.name = "memos/t"
        target.creator = "users/you"
        target.content = "Target"
        var source = Memo()
        source.name = "memos/s"
        source.creator = "users/you"
        source.content = "Source"
        source.snippet = "Source"
        store.receiveOwn([target])

        source.relations = [.reference(from: "memos/s", to: "memos/t")]
        store.receiveOwn([source])
        #expect(store.own["memos/t"]?.referencedBy == ["memos/s"])

        // A list response without snippets keeps the ones already known.
        var withSnippet = source
        withSnippet.relations[0].relatedMemo.snippet = "Target"
        store.receiveOwn([withSnippet])
        store.receiveOwn([source])
        #expect(store.own["memos/s"]?.relationSnippet(for: "memos/t") == "Target")

        source.relations = []
        store.receiveOwn([source])
        #expect(store.own["memos/t"]?.referencedBy == [])
    }
}
