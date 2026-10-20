import Foundation
import Testing
@testable import MemosAPI
@testable import MemosCore

@Suite struct `Default visibility` {
    @Test(arguments: [
        // With “All Spaces” selected, your default applies as-is.
        (MemoVisibility?.none, CaptureOrigin.timeline(space: nil), MemoVisibility.private, MemoVisibility?.none),
        (.public, .timeline(space: nil), .public, nil),
        // Inside a Space with a Private default: Private, with a “Share with Studio” chip.
        (.private, .timeline(space: "spaces/studio"), .private, .space),
        (nil, .timeline(space: "spaces/studio"), .private, .space),
        // Inside a Space with a Protected or Public default: Space, widenable with one tap.
        (.protected, .timeline(space: "spaces/studio"), .space, .protected),
        (.public, .timeline(space: "spaces/studio"), .space, .public),
        // A view filtered to one visibility suggests it rather than applying it.
        (.private, .view(space: nil, visibility: .public), .private, .public),
        (.public, .view(space: nil, visibility: .public), .public, nil),
        // The share sheet and widgets open with no Space.
        (.protected, .shareSheet, .protected, nil),
        // Without a composer the audience is never shown, so the memo stays Private.
        (.public, .silent(explicit: nil), .private, nil),
        (.public, .silent(explicit: .protected), .protected, nil),
    ])
    func `a new memo never starts more open than you chose`(
        defaultVisibility: MemoVisibility?, origin: CaptureOrigin, visibility: MemoVisibility, suggestion: MemoVisibility?
    ) {
        let result = VisibilityRules.initial(defaultVisibility: defaultVisibility, origin: origin)
        #expect(result.visibility == visibility)
        #expect(result.suggestion == suggestion)
    }

    @Test func `removing the Space turns Space visibility into Private`() {
        #expect(VisibilityRules.afterRemovingSpace(.space) == .private)
        #expect(VisibilityRules.afterRemovingSpace(.protected) == .protected)
        #expect(MemoDraft(content: "x", visibility: .space, space: nil).visibility == .private)
    }
}

@Suite struct Markdown {
    @Test func `blocks memos actually contain`() {
        let document = MarkdownDocument(parsing: """
        # Commonplace book

        Keep one here.
        Every quote gets #quote.

        > Read with a pen in hand.

        - [x] Affordances
        - [ ] Re-read
          continued
        1. First

        ```sh
        memos --port 5230
        ```

        | a | b |
        |---|---|
        | 1 | 2 |
        ---
        """)
        #expect(document.title == "Commonplace book")
        #expect(document.blocks == [
            .heading(level: 1, text: "Commonplace book"),
            .paragraph("Keep one here.\nEvery quote gets #quote."),
            .quote("Read with a pen in hand."),
            .list([
                ListItem(marker: .task(checked: true), text: "Affordances", depth: 0, line: 7),
                ListItem(marker: .task(checked: false), text: "Re-read continued", depth: 0, line: 8),
                ListItem(marker: .number(1), text: "First", depth: 0, line: 10),
            ]),
            .code(language: "sh", code: "memos --port 5230"),
            .table(header: ["a", "b"], rows: [["1", "2"]]),
            .rule,
        ])
    }

    @Test func `checking a task rewrites that line only`() {
        let content = "Todo\n- [ ] one\n- [X] two"
        #expect(MarkdownEditing.toggleTask(atLine: 1, in: content) == "Todo\n- [x] one\n- [X] two")
        #expect(MarkdownEditing.toggleTask(atLine: 2, in: content) == "Todo\n- [ ] one\n- [ ] two")
        #expect(MarkdownEditing.toggleTask(atLine: 0, in: content) == content)
    }

    @Test func `tags follow the server's rules`() {
        #expect(ContentAnalysis("Walks #walks, #work/ios and #日本語!").tags == ["walks", "work", "work/ios", "日本語"])
        #expect(ContentAnalysis("Heading\n# Not a tag\nhttps://x.com/#anchor a#b").tags == [])
        #expect(ContentAnalysis("`#code` and\n```\n#block\n```\n#real").tags == ["real"])
        #expect(ContentAnalysis("it's #mira's").tags == ["mira's"])
        #expect(ContentAnalysis("#a/ trailing").tags == ["a"])
        #expect(ContentAnalysis(##"Unit \#13-04, but \\#real"##).tags == ["real"], "an escaped # is text")
    }

    @Test func `a view saved without an icon takes the emoji its title starts with`() {
        var view = MemoView()
        view.title = "🔖 Bookmarks"
        #expect(view.emoji == "🔖" && view.displayTitle == "Bookmarks")
        view.icon.emoji = "📚"
        #expect(view.emoji == "📚" && view.displayTitle == "🔖 Bookmarks")
        view = MemoView()
        view.title = "Reading 2026"
        #expect(view.emoji == nil && view.displayTitle == "Reading 2026")
    }

    @Test func `content flags`() {
        let analysis = ContentAnalysis("See [docs](https://usememos.com) and `x`\n- [ ] open")
        #expect(analysis.hasLink && analysis.hasCode && analysis.hasTaskList && analysis.hasIncompleteTasks)
        #expect(!ContentAnalysis("plain note").hasLink)
        #expect(ContentAnalysis("visit usememos.com today").hasLink)
    }
}

@Suite struct Outbox {
    @Test func `updates merge into a queued create or update`() {
        var outbox: [PendingChange] = []
        outbox.enqueue(PendingChange(memo: "memos/a", operation: .create))
        outbox.enqueue(PendingChange(memo: "memos/a", operation: .update(fields: [.content], base: nil)))
        #expect(outbox.map(\.operation) == [.create])

        let base = BaseVersion(updateTime: .distantPast, content: "v1")
        outbox.enqueue(PendingChange(memo: "memos/b", operation: .update(fields: [.content], base: base)))
        outbox.enqueue(PendingChange(memo: "memos/b", operation: .update(fields: [.pinned], base: nil)))
        #expect(outbox.count == 2)
        #expect(outbox[1].operation == .update(fields: [.content, .pinned], base: base))
    }

    @Test func `the change being uploaded is never merged into`() {
        var outbox: [PendingChange] = []
        outbox.enqueue(PendingChange(memo: "memos/a", operation: .create))
        let inFlight = outbox[0].id
        outbox.enqueue(PendingChange(memo: "memos/a", operation: .update(fields: [.content], base: nil)), inFlight: inFlight)
        #expect(outbox.count == 2)
    }

    @Test func `deleting a memo that never uploaded leaves nothing to send`() {
        var outbox: [PendingChange] = []
        outbox.enqueue(PendingChange(memo: "memos/a", operation: .uploadAttachment(attachment: "attachments/x")))
        outbox.enqueue(PendingChange(memo: "memos/a", operation: .create))
        outbox.enqueue(PendingChange(memo: "memos/a", operation: .delete))
        #expect(outbox.isEmpty)

        outbox.enqueue(PendingChange(memo: "memos/b", operation: .update(fields: [.pinned], base: nil)))
        outbox.enqueue(PendingChange(memo: "memos/b", operation: .delete))
        #expect(outbox.map(\.operation) == [.delete])
    }
}

@Suite struct Session {
    @Test func `the refresh cookie is read from Set-Cookie`() {
        let headers = ["set-cookie": ["other=1; Path=/, memos_refresh=abc.def-ghi; Path=/; HttpOnly; Expires=Wed, 18 Nov 2026 15:17:59 GMT; SameSite=Lax"]]
        #expect(RefreshCookie.value(in: headers) == "abc.def-ghi")
        #expect(RefreshCookie.value(in: ["set-cookie": ["memos_refresh=; Path=/; Max-Age=0"]]) == "")
        #expect(RefreshCookie.value(in: [:]) == nil)
    }

    @Test(arguments: [
        ("memos.example.com", "https://memos.example.com"),
        ("http://192.168.1.4:5230/", "http://192.168.1.4:5230"),
        ("https://example.com/memos//", "https://example.com/memos"),
        (" localhost:5230 ", "https://localhost:5230"),
    ])
    func `server addresses are normalized`(input: String, expected: String) {
        #expect(MemosClient.normalizedServerURL(input)?.absoluteString == expected)
    }

    @Test func `nonsense isn't a server`() {
        #expect(MemosClient.normalizedServerURL("") == nil)
        #expect(MemosClient.normalizedServerURL("ftp://x") == nil)
    }

    @Test func `generated IDs fit the server's pattern`() throws {
        let pattern = try Regex("^[a-zA-Z0-9]([a-zA-Z0-9-]{0,34}[a-zA-Z0-9])?$")
        for _ in 0..<100 {
            #expect(try pattern.wholeMatch(in: ResourceID.generate()) != nil)
        }
    }
}

@MainActor
@Suite struct `Extension drop-off` {
    @Test func `a draft left by an extension joins the queue with its UID and files`() async throws {
        let container = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)")
        let location = AccountLocation(container: container, serverURL: URL(string: "https://memos.example.com")!, user: "users/you")
        let draft = ExtensionDraft(content: "From the share sheet", visibility: .protected, files: [
            .init(filename: "photo.jpg", mimeType: "image/jpeg", storedName: "f0"),
        ])
        try ExtensionInbox.drop(draft, files: ["f0": Data([1, 2, 3])], in: location)

        let store = MemoStore(location: location)
        await store.load()
        ExtensionInbox.drain(into: store)
        let memo = try #require(store.own["memos/\(draft.uid)"])
        #expect(memo.content == "From the share sheet")
        #expect(memo.visibility == .protected)
        #expect(memo.attachments.count == 1 && store.isStaged(memo.attachments[0]))
        #expect(store.outbox.map(\.operation) == [.uploadAttachment(attachment: memo.attachments[0].name), .create])

        // Draining again finds nothing, and never duplicates.
        ExtensionInbox.drain(into: store)
        #expect(store.own.count == 1)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: location.inboxDirectory.path()))?.isEmpty == true)
    }
}
