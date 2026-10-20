import AppIntents
import MemosCore

// Widget settings run in this extension, where the app's `MemoEntity` and its session aren't
// available, so these read the local copy the same way the widgets do.

/// One of your memos, for choosing what a widget shows.
struct WidgetMemoEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Memo"
    static let defaultQuery = WidgetMemoQuery()

    /// The memo's resource name, `memos/{uid}`.
    var id: String
    var preview: String
    var createdAt: Date?
    var pinned = false
    /// Blurred by a tag rule: the picker shows no text either.
    var sensitive = false

    init(_ memo: Memo, rules: TagBlurRules) {
        id = memo.name
        preview = String(InlineText.plain(memo.content).prefix(80))
        createdAt = memo.createdAt
        pinned = memo.pinned
        sensitive = rules.blurs(memo)
    }

    /// A memo deleted or archived since it was chosen. It keeps its place in the settings so
    /// the widget can say so rather than quietly showing something else.
    init(missing id: String) {
        self.id = id
        preview = ""
    }

    var displayRepresentation: DisplayRepresentation {
        guard let createdAt else {
            return DisplayRepresentation(title: "Memo not found", image: .init(systemName: "questionmark.circle"))
        }
        return DisplayRepresentation(
            title: sensitive ? "Sensitive content" : "\(preview)",
            subtitle: "\(createdAt.formatted(date: .abbreviated, time: .omitted))",
            image: pinned ? .init(systemName: "pin.fill") : nil
        )
    }
}

struct WidgetMemoQuery: EntityStringQuery {
    func entities(for identifiers: [WidgetMemoEntity.ID]) async throws -> [WidgetMemoEntity] {
        guard let contents = await WidgetStore.load() else { return [] }
        let memos = Dictionary(contents.memos.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.map { id in
            memos[id].map { WidgetMemoEntity($0, rules: contents.rules) } ?? WidgetMemoEntity(missing: id)
        }
    }

    /// Every word must appear in the memo, ignoring case and accents.
    func entities(matching string: String) async throws -> [WidgetMemoEntity] {
        guard let contents = await WidgetStore.load() else { return [] }
        let words = string.split(whereSeparator: \.isWhitespace)
        return Self.ordered(contents.memos)
            .filter { memo in words.allSatisfy { memo.content.localizedStandardContains($0) } }
            .prefix(30)
            .map { WidgetMemoEntity($0, rules: contents.rules) }
    }

    /// Pinned memos first, then the most recent.
    func suggestedEntities() async throws -> [WidgetMemoEntity] {
        guard let contents = await WidgetStore.load() else { return [] }
        return Self.ordered(contents.memos).prefix(30).map { WidgetMemoEntity($0, rules: contents.rules) }
    }

    private static func ordered(_ memos: [Memo]) -> [Memo] {
        memos.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.createdAt > $1.createdAt }
    }
}

/// One of your tags, for narrowing the Memory widget.
struct WidgetTagEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tag"
    static let defaultQuery = WidgetTagQuery()

    /// The tag without its `#`; nested tags keep their slashes and include their children.
    var id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "#\(id)")
    }
}

struct WidgetTagQuery: EntityStringQuery {
    func entities(for identifiers: [WidgetTagEntity.ID]) async throws -> [WidgetTagEntity] {
        identifiers.map(WidgetTagEntity.init(id:))
    }

    func entities(matching string: String) async throws -> [WidgetTagEntity] {
        let text = string.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        return try await suggestedEntities().filter { text.isEmpty || $0.id.localizedStandardContains(text) }
    }

    /// Your tags, most used first. Tags set to blur are left out: the Memory widget never shows
    /// those memos.
    func suggestedEntities() async throws -> [WidgetTagEntity] {
        guard let contents = await WidgetStore.load() else { return [] }
        var counts: [String: Int] = [:]
        for memo in contents.memos {
            for tag in TagScanner.hierarchy(memo.tags) where !contents.rules.blurs(tag: tag) {
                counts[tag, default: 0] += 1
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { WidgetTagEntity(id: $0.key) }
    }
}
