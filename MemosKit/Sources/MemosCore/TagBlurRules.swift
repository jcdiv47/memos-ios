import Foundation

/// Which tags blur a memo, from your `TAGS` user setting. As on the web, a memo is blurred when
/// any of its tags matches a pattern set to blur its content, such as `nsfw` or `private/.*`.
public struct TagBlurRules: Codable, Equatable, Sendable {
    /// Each tag pattern, and whether memos with a matching tag are blurred.
    public let patterns: [String: Bool]
    /// The patterns as anchored expressions, `^(?:pattern)$`. Invalid ones are left out, as the
    /// web skips them.
    private let expressions: [(blurs: Bool, regex: NSRegularExpression)]

    public init(_ patterns: [String: Bool] = [:]) {
        self.patterns = patterns
        // The web tries patterns in the order the server sent them, which isn't stable; sorting
        // at least gives overlapping patterns the same answer every time.
        expressions = patterns.sorted { $0.key < $1.key }.compactMap { pattern, blurs in
            (try? NSRegularExpression(pattern: "^(?:\(pattern))$")).map { (blurs, $0) }
        }
    }

    public init(_ setting: Memos_Api_UserSetting.TagsSetting) {
        self.init(setting.tags.mapValues(\.blurContent))
    }

    /// Whether the memo's body should start blurred.
    public func blurs(_ memo: Memo) -> Bool {
        !patterns.isEmpty && memo.tags.contains(where: blurs(tag:))
    }

    /// The first rule for the tag decides: its exact name, otherwise the first pattern it matches.
    public func blurs(tag: String) -> Bool {
        if let blurs = patterns[tag] { return blurs }
        let range = NSRange(tag.startIndex..., in: tag)
        return expressions.first { $0.regex.firstMatch(in: tag, range: range) != nil }?.blurs ?? false
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.patterns == rhs.patterns }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode([String: Bool].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(patterns)
    }
}
