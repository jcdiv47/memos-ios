import Foundation

/// The facts a memo filter can test, matching the server's memo filter schema
/// (`filter/schema.go`): the same names, types and string semantics.
public struct MemoFacts: Sendable {
    public var content: String
    /// Resource name of the creator, `users/{username}`.
    public var creator: String
    public var createdAt: Date
    public var updatedAt: Date
    public var pinned: Bool
    /// The memo's tags with every ancestor of a nested tag (`work/ios` adds `work`), as the
    /// server stores them.
    public var tags: [String]
    /// `PRIVATE`, `PROTECTED`, `PUBLIC` or `SPACE`.
    public var visibility: String
    /// `spaces/{space}`, or nil for a memo in no Space.
    public var space: String?
    public var hasTaskList: Bool
    public var hasLink: Bool
    public var hasCode: Bool
    public var hasIncompleteTasks: Bool
    public var hasLocation: Bool
    public var hasAttachments: Bool

    public init(
        content: String, creator: String, createdAt: Date, updatedAt: Date, pinned: Bool, tags: [String],
        visibility: String, space: String?, hasTaskList: Bool, hasLink: Bool, hasCode: Bool,
        hasIncompleteTasks: Bool, hasLocation: Bool, hasAttachments: Bool = false
    ) {
        self.content = content
        self.creator = creator
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pinned = pinned
        self.tags = tags
        self.visibility = visibility
        self.space = space
        self.hasTaskList = hasTaskList
        self.hasLink = hasLink
        self.hasCode = hasCode
        self.hasIncompleteTasks = hasIncompleteTasks
        self.hasLocation = hasLocation
        self.hasAttachments = hasAttachments
    }
}

/// A parsed memo filter that can run against the local copy. Evaluating the same string the
/// server receives is what keeps local results identical to server results.
public struct MemoFilter: Sendable, Equatable {
    public let source: String
    public let expression: CELExpression

    public init(_ source: String) throws(CELError) {
        self.source = source
        self.expression = try CELParser.parse(source)
    }

    /// Whether `facts` match. Throws when the filter uses something only the server can
    /// evaluate, such as `creator_id`.
    public func matches(_ facts: MemoFacts, now: Date = .now) throws(CELError) -> Bool {
        var evaluator = Evaluator(facts: facts, now: now)
        guard case .bool(let result) = try evaluator.evaluate(expression) else {
            throw CELError("The filter doesn’t produce true or false")
        }
        return result
    }
}

struct Evaluator {
    let facts: MemoFacts
    let now: Date
    var bindings: [String: CELValue] = [:]

    private static let caseInsensitiveFields: Set<String> = ["content"]

    mutating func evaluate(_ expression: CELExpression) throws(CELError) -> CELValue {
        switch expression {
        case .literal(let value):
            return value
        case .identifier(let name):
            return try lookup(name)
        case .list(let items):
            var values: [CELValue] = []
            for item in items { values.append(try evaluate(item)) }
            return .list(values)
        case .unary(.not, let operand):
            return .bool(!(try boolean(operand)))
        case .unary(.negate, let operand):
            switch try evaluate(operand) {
            case .int(let value): return .int(-value)
            case .double(let value): return .double(-value)
            case .duration(let value): return .duration(-value)
            default: throw CELError("Can’t negate that value")
            }
        case .binary(let op, let left, let right):
            return try binary(op, left, right)
        case .conditional(let condition, let then, let otherwise):
            return try boolean(condition) ? try evaluate(then) : try evaluate(otherwise)
        case .call(let function, let arguments):
            return try call(function, arguments)
        case .member(let target, let name, let arguments):
            return try member(target, name, arguments)
        case .index(let target, let index):
            guard case .list(let items) = try evaluate(target), case .int(let position) = try evaluate(index),
                  items.indices.contains(Int(position))
            else { throw CELError("Index out of range") }
            return items[Int(position)]
        }
    }

    private mutating func boolean(_ expression: CELExpression) throws(CELError) -> Bool {
        guard case .bool(let value) = try evaluate(expression) else {
            throw CELError("Expected true or false")
        }
        return value
    }

    private func lookup(_ name: String) throws(CELError) -> CELValue {
        if let bound = bindings[name] { return bound }
        switch name {
        case "content": return .string(facts.content)
        case "creator": return .string(facts.creator)
        case "created_ts": return .timestamp(facts.createdAt)
        case "updated_ts": return .timestamp(facts.updatedAt)
        case "pinned": return .bool(facts.pinned)
        case "tag", "tags": return .list(facts.tags.map(CELValue.string))
        case "visibility": return .string(facts.visibility)
        case "space": return facts.space.map(CELValue.string) ?? .null
        case "has_task_list": return .bool(facts.hasTaskList)
        case "has_link": return .bool(facts.hasLink)
        case "has_code": return .bool(facts.hasCode)
        case "has_incomplete_tasks": return .bool(facts.hasIncompleteTasks)
        case "has_location": return .bool(facts.hasLocation)
        case "has_attachments": return .bool(facts.hasAttachments)
        case "now": return .timestamp(now)
        default: throw CELError("Unknown field ‘\(name)’")
        }
    }

    private mutating func binary(_ op: CELExpression.BinaryOperator, _ left: CELExpression, _ right: CELExpression) throws(CELError) -> CELValue {
        switch op {
        case .and:
            guard try boolean(left) else { return .bool(false) }
            return .bool(try boolean(right))
        case .or:
            if try boolean(left) { return .bool(true) }
            return .bool(try boolean(right))
        default:
            break
        }

        // `tag` stands for any one of the memo's tags: `tag in [...]` and `tag == "x"` match
        // when some tag does.
        if left == .identifier("tag"), bindings["tag"] == nil {
            let tags = facts.tags.map(CELValue.string)
            switch op {
            case .in:
                guard case .list(let candidates) = try evaluate(right) else { throw CELError("‘in’ needs a list") }
                return .bool(tags.contains { candidates.contains($0) })
            case .equal:
                return .bool(tags.contains(try evaluate(right)))
            case .notEqual:
                return .bool(!tags.contains(try evaluate(right)))
            default:
                throw CELError("Unsupported comparison on tag")
            }
        }

        let lhs = try evaluate(left)
        let rhs = try evaluate(right)
        switch op {
        case .equal: return .bool(Self.equal(lhs, rhs))
        case .notEqual: return .bool(!Self.equal(lhs, rhs))
        case .in:
            guard case .list(let items) = rhs else { throw CELError("‘in’ needs a list") }
            return .bool(items.contains { Self.equal($0, lhs) })
        case .less, .lessOrEqual, .greater, .greaterOrEqual:
            let order = try Self.compare(lhs, rhs)
            switch op {
            case .less: return .bool(order < 0)
            case .lessOrEqual: return .bool(order <= 0)
            case .greater: return .bool(order > 0)
            default: return .bool(order >= 0)
            }
        case .add, .subtract, .multiply, .divide, .remainder:
            return try Self.arithmetic(op, lhs, rhs)
        case .and, .or:
            preconditionFailure("handled above")
        }
    }

    static func equal(_ lhs: CELValue, _ rhs: CELValue) -> Bool {
        switch (lhs, rhs) {
        case (.int(let a), .double(let b)): Double(a) == b
        case (.double(let a), .int(let b)): a == Double(b)
        default: lhs == rhs
        }
    }

    static func compare(_ lhs: CELValue, _ rhs: CELValue) throws(CELError) -> Int {
        func order<T: Comparable>(_ a: T, _ b: T) -> Int { a < b ? -1 : (a > b ? 1 : 0) }
        switch (lhs, rhs) {
        case (.int(let a), .int(let b)): return order(a, b)
        case (.double(let a), .double(let b)): return order(a, b)
        case (.int(let a), .double(let b)): return order(Double(a), b)
        case (.double(let a), .int(let b)): return order(a, Double(b))
        case (.string(let a), .string(let b)): return order(a, b)
        case (.timestamp(let a), .timestamp(let b)): return order(a, b)
        case (.duration(let a), .duration(let b)): return order(a, b)
        // The server folds timestamps to epoch seconds, so comparing one to a number works.
        case (.timestamp(let a), .int(let b)): return order(a.timeIntervalSince1970, Double(b))
        case (.int(let a), .timestamp(let b)): return order(Double(a), b.timeIntervalSince1970)
        default: throw CELError("Can’t compare those values")
        }
    }

    static func arithmetic(_ op: CELExpression.BinaryOperator, _ lhs: CELValue, _ rhs: CELValue) throws(CELError) -> CELValue {
        switch (op, lhs, rhs) {
        case (.add, .timestamp(let t), .duration(let d)), (.add, .duration(let d), .timestamp(let t)): return .timestamp(t + d)
        case (.subtract, .timestamp(let t), .duration(let d)): return .timestamp(t - d)
        case (.subtract, .timestamp(let a), .timestamp(let b)): return .duration(a.timeIntervalSince(b))
        case (.add, .duration(let a), .duration(let b)): return .duration(a + b)
        case (.subtract, .duration(let a), .duration(let b)): return .duration(a - b)
        case (.add, .string(let a), .string(let b)): return .string(a + b)
        case (.add, .list(let a), .list(let b)): return .list(a + b)
        case (_, .int(let a), .int(let b)):
            switch op {
            case .add: return .int(a &+ b)
            case .subtract: return .int(a &- b)
            case .multiply: return .int(a &* b)
            case .divide: guard b != 0 else { throw CELError("Division by zero") }; return .int(a / b)
            case .remainder: guard b != 0 else { throw CELError("Division by zero") }; return .int(a % b)
            default: break
            }
        case (_, .double, _), (_, _, .double):
            guard let a = lhs.number, let b = rhs.number else { break }
            switch op {
            case .add: return .double(a + b)
            case .subtract: return .double(a - b)
            case .multiply: return .double(a * b)
            case .divide: return .double(a / b)
            default: break
            }
        default:
            break
        }
        throw CELError("Unsupported arithmetic")
    }

    private mutating func call(_ function: String, _ arguments: [CELExpression]) throws(CELError) -> CELValue {
        var values: [CELValue] = []
        for argument in arguments { values.append(try evaluate(argument)) }
        guard values.count == 1, let value = values.first else {
            throw CELError("Unsupported function ‘\(function)’")
        }
        switch (function, value) {
        case ("size", _): return try Self.size(value)
        case ("timestamp", .string(let text)):
            guard let date = Self.parseTimestamp(text) else { throw CELError("Invalid timestamp \(text)") }
            return .timestamp(date)
        case ("timestamp", .int(let seconds)): return .timestamp(Date(timeIntervalSince1970: TimeInterval(seconds)))
        case ("duration", .string(let text)):
            guard let duration = Self.parseDuration(text) else { throw CELError("Invalid duration \(text)") }
            return .duration(duration)
        case ("int", .timestamp(let date)): return .int(Int64(date.timeIntervalSince1970))
        case ("int", .int(let int)): return .int(int)
        case ("int", .double(let double)): return .int(Int64(double))
        case ("string", .string(let string)): return .string(string)
        default: throw CELError("Unsupported function ‘\(function)’")
        }
    }

    private mutating func member(_ target: CELExpression, _ name: String, _ arguments: [CELExpression]?) throws(CELError) -> CELValue {
        guard let arguments else { throw CELError("Unsupported field access ‘.\(name)’") }

        if target == .identifier("sets") {
            guard arguments.count == 2, case .list(let set) = try evaluate(arguments[0]),
                  case .list(let other) = try evaluate(arguments[1])
            else { throw CELError("sets.\(name) needs two lists") }
            switch name {
            case "contains": return .bool(other.allSatisfy { set.contains($0) })
            case "intersects": return .bool(other.contains { set.contains($0) })
            case "equivalent": return .bool(other.allSatisfy { set.contains($0) } && set.allSatisfy { other.contains($0) })
            default: throw CELError("Unsupported function ‘sets.\(name)’")
            }
        }

        // Comprehensions bind their first argument as a variable over the list.
        if ["exists", "all", "exists_one", "filter", "map"].contains(name),
           arguments.count == 2, case .identifier(let variable) = arguments[0] {
            guard case .list(let items) = try evaluate(target) else { throw CELError("\(name)() needs a list") }
            var results: [CELValue] = []
            var matched: [CELValue] = []
            let saved = bindings[variable]
            defer { bindings[variable] = saved }
            for item in items {
                bindings[variable] = item
                let result = try evaluate(arguments[1])
                results.append(result)
                if result == .bool(true) { matched.append(item) }
            }
            switch name {
            case "exists": return .bool(!matched.isEmpty)
            case "all": return .bool(matched.count == items.count)
            case "exists_one": return .bool(matched.count == 1)
            case "filter": return .list(matched)
            default: return .list(results)
            }
        }

        let receiver = try evaluate(target)
        var values: [CELValue] = []
        for argument in arguments { values.append(try evaluate(argument)) }

        if case .string(let string) = receiver {
            // The server matches content with a case-insensitive LIKE, and everything else
            // (tags included) exactly.
            let insensitive: Bool
            if case .identifier(let field) = target, bindings[field] == nil {
                insensitive = Self.caseInsensitiveFields.contains(field)
            } else {
                insensitive = false
            }
            let options: String.CompareOptions = insensitive ? [.caseInsensitive] : []
            if name == "size", values.isEmpty {
                return .int(Int64(string.unicodeScalars.count))
            }
            if values.count == 1, case .string(let argument) = values[0] {
                switch name {
                case "contains":
                    return .bool(argument.isEmpty || string.range(of: argument, options: options) != nil)
                case "startsWith":
                    return .bool(argument.isEmpty || string.range(of: argument, options: options.union(.anchored)) != nil)
                case "endsWith":
                    return .bool(argument.isEmpty || string.range(of: argument, options: options.union([.anchored, .backwards])) != nil)
                case "matches":
                    guard let regex = try? NSRegularExpression(pattern: argument) else { throw CELError("Invalid pattern \(argument)") }
                    return .bool(regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil)
                default:
                    break
                }
            }
        }

        if case .list(let items) = receiver, name == "size", values.isEmpty {
            return .int(Int64(items.count))
        }

        if case .timestamp(let date) = receiver, values.isEmpty {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let parts = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
            switch name {
            case "getFullYear": return .int(Int64(parts.year!))
            case "getMonth": return .int(Int64(parts.month! - 1))
            case "getDate": return .int(Int64(parts.day!))
            case "getDayOfMonth": return .int(Int64(parts.day! - 1))
            case "getDayOfWeek": return .int(Int64(parts.weekday! - 1))
            case "getDayOfYear": return .int(Int64(calendar.ordinality(of: .day, in: .year, for: date)! - 1))
            case "getHours": return .int(Int64(parts.hour!))
            case "getMinutes": return .int(Int64(parts.minute!))
            case "getSeconds": return .int(Int64(parts.second!))
            default: break
            }
        }

        throw CELError("Unsupported function ‘\(name)’")
    }

    static func size(_ value: CELValue) throws(CELError) -> CELValue {
        switch value {
        case .string(let string): .int(Int64(string.unicodeScalars.count))
        case .list(let items): .int(Int64(items.count))
        default: throw CELError("size() needs a string or a list")
        }
    }

    static func parseTimestamp(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return try? Date(text, strategy: fractional)
    }

    /// Parses a Go duration such as `168h`, `1h30m` or `-1.5s`.
    static func parseDuration(_ text: String) -> TimeInterval? {
        var rest = Substring(text)
        var sign = 1.0
        if rest.first == "-" { sign = -1; rest.removeFirst() } else if rest.first == "+" { rest.removeFirst() }
        if rest == "0" { return 0 }
        let units: [(String, Double)] = [("ns", 1e-9), ("us", 1e-6), ("µs", 1e-6), ("ms", 1e-3), ("s", 1), ("m", 60), ("h", 3600)]
        var total = 0.0
        guard !rest.isEmpty else { return nil }
        while !rest.isEmpty {
            let number = rest.prefix { $0.isNumber || $0 == "." }
            guard let value = Double(number) else { return nil }
            rest = rest.dropFirst(number.count)
            guard let (unit, scale) = units.first(where: { rest.hasPrefix($0.0) && !(($0.0 == "m") && rest.hasPrefix("ms")) }) else { return nil }
            rest = rest.dropFirst(unit.count)
            total += value * scale
        }
        return sign * total
    }
}

extension CELValue {
    var number: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
}
