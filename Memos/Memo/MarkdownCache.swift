import MemosCore
import SwiftUI

/// Parsed Markdown, kept between renders. A card's body runs again on every scroll and store
/// change, and parsing its content is the most expensive thing it does; a search row's excerpt
/// is rebuilt on every keystroke. Colors in the results are asset colors, which resolve at draw
/// time, so a cached string stays right across light and dark.
enum MarkdownCache {
    private final class Box<Value> {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private static let documents: NSCache<NSString, Box<MarkdownDocument>> = {
        let cache = NSCache<NSString, Box<MarkdownDocument>>()
        cache.countLimit = 500
        return cache
    }()

    private static let inlines: NSCache<NSString, Box<AttributedString>> = {
        let cache = NSCache<NSString, Box<AttributedString>>()
        cache.countLimit = 3000
        return cache
    }()

    private static let plainTexts: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 1000
        return cache
    }()

    static func document(_ content: String) -> MarkdownDocument {
        let key = content as NSString
        if let hit = documents.object(forKey: key) { return hit.value }
        let document = MarkdownDocument(parsing: content)
        documents.setObject(Box(document), forKey: key)
        return document
    }

    /// ``InlineMarkdown/render(_:highlights:underlineTags:)``, cached.
    static func inline(_ text: String, highlights: [String] = [], underlineTags: Bool = false) -> AttributedString {
        // Unit and record separators can't appear in a search word, so the key is unambiguous.
        let key = "\(underlineTags ? 1 : 0)\u{1F}\(highlights.joined(separator: "\u{1F}"))\u{1E}\(text)" as NSString
        if let hit = inlines.object(forKey: key) { return hit.value }
        let rendered = InlineMarkdown.render(text, highlights: highlights, underlineTags: underlineTags)
        inlines.setObject(Box(rendered), forKey: key)
        return rendered
    }

    /// ``MemosCore/Memo/plainText``, cached by content.
    static func plainText(of memo: Memo) -> String {
        let key = memo.content as NSString
        if let hit = plainTexts.object(forKey: key) { return hit as String }
        let text = memo.plainText
        plainTexts.setObject(text as NSString, forKey: key)
        return text
    }
}
