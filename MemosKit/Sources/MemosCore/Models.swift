import Foundation
@_exported import MemosAPI
import SwiftProtobuf

public typealias Memo = Memos_Api_Memo
public typealias MemoVisibility = Memos_Api_Visibility
public typealias MemoState = Memos_Api_State
public typealias Space = Memos_Api_Space
public typealias User = Memos_Api_User
public typealias Attachment = Memos_Api_Attachment
public typealias MemoView = Memos_Api_MemoView
public typealias Reaction = Memos_Api_Reaction
public typealias UserNotification = Memos_Api_UserNotification
public typealias MemoLocation = Memos_Api_Location
public typealias MemoRelation = Memos_Api_MemoRelation

extension Memo {
    /// The final segment of the resource name, `memos/{uid}`.
    public var uid: String { String(name.dropFirst("memos/".count)) }

    public var createdAt: Date { createTime.date }
    public var updatedAt: Date { updateTime.date }

    public var isArchived: Bool { state == .archived }

    /// The Space resource name, or nil when the memo is in no Space.
    public var spaceName: String? {
        get { hasSpace && !space.isEmpty ? space : nil }
        set {
            if let newValue { space = newValue } else { clearSpace() }
        }
    }

    public var locationIfSet: MemoLocation? { hasLocation ? location : nil }

    /// Recomputes what the server derives from content (tags, title and content flags), so a
    /// memo edited offline filters the same way it will once uploaded.
    public mutating func refreshDerivedFields() {
        let analysis = ContentAnalysis(content)
        tags = analysis.tags
        property.title = analysis.title
        property.hasLink_p = analysis.hasLink
        property.hasCode_p = analysis.hasCode
        property.hasTaskList_p = analysis.hasTaskList
        property.hasIncompleteTasks_p = analysis.hasIncompleteTasks
        snippet = String(content.prefix(120))
    }

    public var facts: MemoFacts {
        MemoFacts(
            content: content,
            creator: creator,
            createdAt: createdAt,
            updatedAt: updatedAt,
            pinned: pinned,
            tags: TagScanner.hierarchy(tags),
            visibility: visibility.filterValue,
            space: spaceName,
            hasTaskList: property.hasTaskList_p,
            hasLink: property.hasLink_p,
            hasCode: property.hasCode_p,
            hasIncompleteTasks: property.hasIncompleteTasks_p,
            hasLocation: hasLocation,
            hasAttachments: !attachments.isEmpty
        )
    }

    /// Reactions grouped by emoji, in the order each emoji was first used.
    public var reactionCounts: [(emoji: String, count: Int, creators: [String])] {
        var order: [String] = []
        var creators: [String: [String]] = [:]
        for reaction in reactions {
            if creators[reaction.reactionType] == nil { order.append(reaction.reactionType) }
            creators[reaction.reactionType, default: []].append(reaction.creator)
        }
        return order.map { ($0, creators[$0]!.count, creators[$0]!) }
    }

    /// Comments are memos too; their parent is the memo they answer.
    public var isComment: Bool { hasParent && !parent.isEmpty }

    /// The memos this one links to, in the order they were linked. The server sends both
    /// directions in `relations`; these are the ones going out.
    public var references: [String] {
        var seen: Set<String> = []
        return relations.compactMap { relation in
            guard relation.type == .reference, relation.memo.name == name,
                  relation.relatedMemo.name != name, seen.insert(relation.relatedMemo.name).inserted
            else { return nil }
            return relation.relatedMemo.name
        }
    }

    /// The memos that link to this one, the web's “Referenced by”.
    public var referencedBy: [String] {
        var seen: Set<String> = []
        return relations.compactMap { relation in
            guard relation.type == .reference, relation.relatedMemo.name == name,
                  relation.memo.name != name, seen.insert(relation.memo.name).inserted
            else { return nil }
            return relation.memo.name
        }
    }

    /// The snippet the server sent for a memo on the other end of one of the relations, if any.
    /// List responses leave it empty.
    public func relationSnippet(for other: String) -> String? {
        for relation in relations where relation.type == .reference {
            if relation.memo.name == name, relation.relatedMemo.name == other, !relation.relatedMemo.snippet.isEmpty {
                return relation.relatedMemo.snippet
            }
            if relation.relatedMemo.name == name, relation.memo.name == other, !relation.memo.snippet.isEmpty {
                return relation.memo.snippet
            }
        }
        return nil
    }

    /// Replaces the memos this one links to, keeping the links into it and the snippets already
    /// known for links that stay.
    public mutating func setReferences(_ targets: [String]) {
        var seen: Set<String> = [name]
        let targets = targets.filter { seen.insert($0).inserted }
        let kept = Dictionary(relations.filter { $0.type == .reference && $0.memo.name == name }.map { ($0.relatedMemo.name, $0) }, uniquingKeysWith: { first, _ in first })
        let source = name
        relations.removeAll { $0.type == .reference && $0.memo.name == source }
        relations += targets.map { target in
            kept[target] ?? MemoRelation.reference(from: source, to: target)
        }
    }

    /// The links this memo sends when it uploads its references: names only.
    public var referenceRelations: [MemoRelation] {
        references.map { MemoRelation.reference(from: name, to: $0) }
    }
}

extension MemoRelation {
    public static func reference(from source: String, to target: String, sourceSnippet: String = "") -> MemoRelation {
        var relation = MemoRelation()
        relation.type = .reference
        relation.memo.name = source
        relation.memo.snippet = sourceSnippet
        relation.relatedMemo.name = target
        return relation
    }
}

extension MemoVisibility {
    /// How the visibility is written in filters and in the `memo_visibility` setting.
    public var filterValue: String {
        switch self {
        case .private: "PRIVATE"
        case .protected: "PROTECTED"
        case .public: "PUBLIC"
        case .space: "SPACE"
        default: "PRIVATE"
        }
    }

    public init?(filterValue: String) {
        switch filterValue.uppercased() {
        case "PRIVATE": self = .private
        case "PROTECTED": self = .protected
        case "PUBLIC": self = .public
        case "SPACE": self = .space
        default: return nil
        }
    }

    public static let choices: [MemoVisibility] = [.private, .space, .protected, .public]
}

extension User {
    public var displayLabel: String { displayName.isEmpty ? username : displayName }
}

extension Space {
    /// The emoji icon when there is one, otherwise the first letter of the title.
    public var monogram: String {
        if case .emoji(let emoji) = icon.value, !emoji.isEmpty { return emoji }
        return title.first.map { String($0).uppercased() } ?? "∗"
    }
}

extension MemoView {
    /// The view's icon, or for a view saved without one, as Memos 0.31's web app does, the emoji
    /// its title starts with.
    public var emoji: String? {
        if case .emoji(let emoji) = icon.value, !emoji.isEmpty { return emoji }
        return leadingEmoji.map(String.init)
    }

    /// The title, without the emoji ``emoji`` took from it.
    public var displayTitle: String {
        if case .emoji(let emoji) = icon.value, !emoji.isEmpty { return title }
        guard leadingEmoji != nil else { return title }
        return String(title.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private var leadingEmoji: Character? {
        guard let first = title.first, first.unicodeScalars.first?.properties.isEmojiPresentation == true
            || first.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0xFF })
        else { return nil }
        return first
    }
}

extension Google_Protobuf_Timestamp {
    public init(_ date: Date) {
        self.init(date: date)
    }
}

/// Resource IDs the app picks itself, so a create can be retried safely: if the server says the
/// ID already exists, the earlier attempt went through.
public enum ResourceID {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz123456789")

    /// 22 characters, matching `^[a-zA-Z0-9]([a-zA-Z0-9-]{0,34}[a-zA-Z0-9])?$`.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<22).map { _ in alphabet[Int(generator.next(upperBound: UInt(alphabet.count)))] })
    }
}

/// Convenience for resource names.
public enum ResourceName {
    public static func user(_ name: String) -> String {
        name.hasPrefix("users/") ? name : "users/\(name)"
    }

    /// `users/mira` → `mira`.
    public static func lastSegment(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }
}
