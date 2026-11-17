import Foundation

/// A filter chip in the search field.
public enum SearchToken: Hashable, Sendable {
    case tag(String)
    case openTasks
    case tasks
    case links
    case code
    case places
    case pinned
    case visibility(MemoVisibility)
    case space(name: String, title: String)
    case date(DateRange)

    public enum DateRange: Hashable, Sendable {
        case today
        case thisWeek
        case thisMonth
        case between(Date, Date)
    }

    /// The filter clause this token adds. Relative dates use `now` and `duration`, so a view
    /// saved from them keeps meaning “this week” when the web evaluates it later.
    public var filterClause: String {
        switch self {
        case .tag(let tag): "tag in [\(CELString.quote(tag))]"
        case .openTasks: "has_incomplete_tasks"
        case .tasks: "has_task_list"
        case .links: "has_link"
        case .code: "has_code"
        case .places: "has_location"
        case .pinned: "pinned"
        case .visibility(let visibility): "visibility == \(CELString.quote(visibility.filterValue))"
        case .space(let name, _): "space == \(CELString.quote(name))"
        case .date(.today): "created_ts > now - duration(\"24h\")"
        case .date(.thisWeek): "created_ts > now - duration(\"168h\")"
        case .date(.thisMonth): "created_ts > now - duration(\"720h\")"
        case .date(.between(let start, let end)):
            "created_ts >= timestamp(\(CELString.quote(CELString.timestamp(start)))) && created_ts < timestamp(\(CELString.quote(CELString.timestamp(end))))"
        }
    }

    /// The chip's title, in the reader's language. Tags and Space titles are shown as written.
    public var label: String {
        switch self {
        case .tag(let tag): "#\(tag)"
        case .openTasks: String(localized: "Open tasks", bundle: .module, comment: "A search filter: memos with unchecked tasks.")
        case .tasks: String(localized: "Tasks", bundle: .module, comment: "A search filter: memos with a task list.")
        case .links: String(localized: "Links", bundle: .module, comment: "A search filter: memos with a link.")
        case .code: String(localized: "Code", bundle: .module, comment: "A search filter: memos with code.")
        case .places: String(localized: "Places", bundle: .module, comment: "A search filter: memos with a location.")
        case .pinned: String(localized: "Pinned", bundle: .module, comment: "A search filter: pinned memos.")
        case .visibility(let visibility): visibility.label
        case .space(_, let title): title
        case .date(.today): String(localized: "Today", bundle: .module, comment: "A search filter: memos created in the last 24 hours.")
        case .date(.thisWeek): String(localized: "This week", bundle: .module, comment: "A search filter: memos created in the last 7 days.")
        case .date(.thisMonth): String(localized: "This month", bundle: .module, comment: "A search filter: memos created in the last 30 days.")
        case .date(.between(let start, let end)):
            (start..<end).formatted(date: .abbreviated, time: .omitted)
        }
    }

    public var systemImage: String {
        switch self {
        case .tag: "number"
        case .openTasks: "circle"
        case .tasks: "checklist"
        case .links: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .places: "mappin.and.ellipse"
        case .pinned: "pin"
        case .visibility(let visibility): visibility.systemImage
        case .space: "square.stack"
        case .date: "calendar"
        }
    }

    /// The filters offered before typing.
    public static let commonFilters: [SearchToken] = [.openTasks, .date(.thisWeek), .places, .tasks, .links, .code, .pinned]
}

extension MemoVisibility {
    /// The visibility's name, in the reader's language, matching the web's.
    public var label: String {
        switch self {
        case .protected: String(localized: "Protected", bundle: .module, comment: "Memo visibility: anyone signed in to the server can read it.")
        case .public: String(localized: "Public", bundle: .module, comment: "Memo visibility: anyone can read it, even signed out.")
        case .space: String(localized: "Space", bundle: .module, comment: "Memo visibility: only the members of the memo's Space can read it.")
        default: String(localized: "Private", bundle: .module, comment: "Memo visibility: only you can read it.")
        }
    }

    public var systemImage: String {
        switch self {
        case .private: "lock"
        case .protected: "person.2"
        case .public: "globe"
        // Only the Space's members: people with a key. The Space itself is `square.stack`.
        case .space: "person.2.badge.key"
        default: "lock"
        }
    }
}

/// What's in the search field: free text plus tokens. Everything combines with `&&`, and the
/// same string runs on the server and against the local copy.
public struct SearchQuery: Equatable, Sendable {
    public var text: String
    public var tokens: [SearchToken]

    public init(text: String = "", tokens: [SearchToken] = []) {
        self.text = text
        self.tokens = tokens
    }

    public var isEmpty: Bool { words.isEmpty && tokens.isEmpty }

    /// Each whitespace-separated word adds its own `content.contains` clause.
    public var words: [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The filter for the field's contents, or nil when the field is empty. The Mine scope adds
    /// `creator` here rather than as a token.
    public func filter(creator: String? = nil) -> String? {
        var clauses = words.map { "content.contains(\(CELString.quote($0)))" }
        clauses += tokens.map(\.filterClause)
        if let creator {
            clauses.append("creator == \(CELString.quote(creator))")
        }
        guard !clauses.isEmpty else { return nil }
        return clauses.count == 1 ? clauses[0] : clauses.map { $0.contains("&&") ? "(\($0))" : $0 }.joined(separator: " && ")
    }

    /// The query without its Space token, for “Search all Spaces”.
    public func removingSpace() -> SearchQuery {
        var copy = self
        copy.tokens.removeAll { if case .space = $0 { true } else { false } }
        return copy
    }

    public var spaceToken: SearchToken? {
        tokens.first { if case .space = $0 { true } else { false } }
    }
}

public enum CELString {
    public static func quote(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .omitted))
    }
}

extension MemoFilter {
    /// The visibility the filter pins with a top-level `visibility == "X"`, if any. The composer
    /// suggests it for memos captured inside such a view.
    public var pinnedVisibility: MemoVisibility? {
        Self.conjuncts(expression).lazy.compactMap { clause -> MemoVisibility? in
            guard case .binary(.equal, .identifier("visibility"), .literal(.string(let value))) = clause else { return nil }
            return MemoVisibility(filterValue: value)
        }.first
    }

    /// The Space the filter pins with a top-level `space == "spaces/x"`, if any.
    public var pinnedSpace: String? {
        Self.conjuncts(expression).lazy.compactMap { clause -> String? in
            guard case .binary(.equal, .identifier("space"), .literal(.string(let value))) = clause else { return nil }
            return value
        }.first
    }

    static func conjuncts(_ expression: CELExpression) -> [CELExpression] {
        if case .binary(.and, let left, let right) = expression {
            return conjuncts(left) + conjuncts(right)
        }
        return [expression]
    }
}

extension SearchToken: Identifiable {
    public var id: Self { self }
}

extension MemoFilter {
    /// The filter as search tokens, when every top-level `&&` clause is one a token writes, so
    /// a saved view can be described in words rather than code. `nil` for anything else, such as
    /// an `||`, a negation, or a tag list with more than one tag. A Space clause takes its title
    /// from `spaceTitle`, and falls back to the Space's name.
    public func tokens(spaceTitle: (String) -> String? = { _ in nil }) -> [SearchToken]? {
        var tokens: [SearchToken] = []
        for clause in Self.conjuncts(expression) {
            guard let token = Self.token(for: clause, spaceTitle: spaceTitle) else { return nil }
            tokens.append(token)
        }
        return tokens
    }

    private static func token(for clause: CELExpression, spaceTitle: (String) -> String?) -> SearchToken? {
        switch clause {
        case .binary(.in, .identifier("tag"), .list(let items)):
            guard items.count == 1, case .literal(.string(let tag)) = items[0] else { return nil }
            return .tag(tag)
        case .binary(.equal, .identifier("space"), .literal(.string(let name))):
            return .space(name: name, title: spaceTitle(name) ?? name)
        default:
            return fixedTokens.first { $0.expression == clause }?.token
        }
    }

    /// Every token whose clause doesn't carry a value of its own, parsed once.
    private static let fixedTokens: [(token: SearchToken, expression: CELExpression)] = {
        let tokens: [SearchToken] = [.openTasks, .tasks, .links, .code, .places, .pinned, .date(.today), .date(.thisWeek), .date(.thisMonth)]
            + [MemoVisibility.private, .protected, .public, .space].map { .visibility($0) }
        return tokens.compactMap { token in
            (try? MemoFilter(token.filterClause)).map { (token, $0.expression) }
        }
    }()
}
