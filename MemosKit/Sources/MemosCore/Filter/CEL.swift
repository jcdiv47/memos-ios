import Foundation

/// The subset of CEL that the Memos server accepts in memo filters, parsed into a tree the app
/// can evaluate against its local copy. Saved views are written on the web as well as here, so
/// this covers the whole server grammar rather than only what the app's own search produces.
public indirect enum CELExpression: Equatable, Sendable {
    case literal(CELValue)
    case identifier(String)
    case list([CELExpression])
    case unary(UnaryOperator, CELExpression)
    case binary(BinaryOperator, CELExpression, CELExpression)
    case conditional(CELExpression, CELExpression, CELExpression)
    case call(function: String, arguments: [CELExpression])
    case member(CELExpression, name: String, arguments: [CELExpression]?)
    case index(CELExpression, CELExpression)

    public enum UnaryOperator: String, Sendable { case not = "!", negate = "-" }

    public enum BinaryOperator: String, Sendable {
        case or = "||", and = "&&"
        case equal = "==", notEqual = "!=", less = "<", lessOrEqual = "<=", greater = ">", greaterOrEqual = ">="
        case `in` = "in"
        case add = "+", subtract = "-", multiply = "*", divide = "/", remainder = "%"
    }
}

public enum CELValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case list([CELValue])
    case timestamp(Date)
    case duration(TimeInterval)
}

public struct CELError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - Parsing

public enum CELParser {
    public static func parse(_ source: String) throws(CELError) -> CELExpression {
        var parser = Parser(tokens: try Lexer.tokenize(source))
        let expression = try parser.parseExpression()
        guard parser.peek == .end else {
            throw CELError("Unexpected \(parser.peek) in filter")
        }
        return expression
    }
}

enum Token: Equatable, CustomStringConvertible {
    case identifier(String)
    case string(String)
    case int(Int64)
    case double(Double)
    case symbol(String)
    case end

    var description: String {
        switch self {
        case .identifier(let name): "‘\(name)’"
        case .string(let value): "\"\(value)\""
        case .int(let value): "\(value)"
        case .double(let value): "\(value)"
        case .symbol(let symbol): "‘\(symbol)’"
        case .end: "end of filter"
        }
    }
}

enum Lexer {
    private static let symbols = ["&&", "||", "==", "!=", "<=", ">=", "<", ">", "!", "(", ")", "[", "]", ",", ".", "+", "-", "*", "/", "%", "?", ":"]

    static func tokenize(_ source: String) throws(CELError) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(source)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            if character == "\"" || character == "'" {
                let (value, next) = try readString(characters, from: index, raw: false)
                tokens.append(.string(value))
                index = next
                continue
            }
            if (character == "r" || character == "R"), index + 1 < characters.count, characters[index + 1] == "\"" || characters[index + 1] == "'" {
                let (value, next) = try readString(characters, from: index + 1, raw: true)
                tokens.append(.string(value))
                index = next
                continue
            }
            if character.isNumber {
                var end = index
                var isDouble = false
                while end < characters.count, characters[end].isNumber || (characters[end] == "." && !isDouble && end + 1 < characters.count && characters[end + 1].isNumber) {
                    if characters[end] == "." { isDouble = true }
                    end += 1
                }
                let text = String(characters[index..<end])
                if end < characters.count, characters[end] == "u" || characters[end] == "U" { end += 1 }
                if isDouble, let value = Double(text) {
                    tokens.append(.double(value))
                } else if let value = Int64(text) {
                    tokens.append(.int(value))
                } else {
                    throw CELError("Invalid number \(text)")
                }
                index = end
                continue
            }
            if character.isLetter || character == "_" {
                var end = index
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" {
                    end += 1
                }
                tokens.append(.identifier(String(characters[index..<end])))
                index = end
                continue
            }
            if let symbol = symbols.first(where: { matches($0, characters, at: index) }) {
                tokens.append(.symbol(symbol))
                index += symbol.count
                continue
            }
            throw CELError("Unexpected character ‘\(character)’ in filter")
        }
        tokens.append(.end)
        return tokens
    }

    private static func matches(_ symbol: String, _ characters: [Character], at index: Int) -> Bool {
        let symbolCharacters = Array(symbol)
        guard index + symbolCharacters.count <= characters.count else { return false }
        return Array(characters[index..<index + symbolCharacters.count]) == symbolCharacters
    }

    private static func readString(_ characters: [Character], from start: Int, raw: Bool) throws(CELError) -> (String, Int) {
        let quote = characters[start]
        var index = start + 1
        var value = ""
        while index < characters.count {
            let character = characters[index]
            if character == quote {
                return (value, index + 1)
            }
            if character == "\\", !raw, index + 1 < characters.count {
                let escaped = characters[index + 1]
                switch escaped {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "r": value.append("\r")
                case "\\", "\"", "'", "`", "?": value.append(escaped)
                default: value.append("\\"); value.append(escaped)
                }
                index += 2
                continue
            }
            value.append(character)
            index += 1
        }
        throw CELError("Unterminated string in filter")
    }
}

struct Parser {
    let tokens: [Token]
    var position = 0

    init(tokens: [Token]) { self.tokens = tokens }

    var peek: Token { tokens[position] }

    mutating func advance() -> Token {
        let token = tokens[position]
        if position < tokens.count - 1 { position += 1 }
        return token
    }

    mutating func consume(_ symbol: String) -> Bool {
        if peek == .symbol(symbol) {
            _ = advance()
            return true
        }
        return false
    }

    mutating func expect(_ symbol: String) throws(CELError) {
        guard consume(symbol) else { throw CELError("Expected ‘\(symbol)’ but found \(peek)") }
    }

    mutating func parseExpression() throws(CELError) -> CELExpression {
        let condition = try parseBinary(precedence: 0)
        if consume("?") {
            let then = try parseExpression()
            try expect(":")
            let otherwise = try parseExpression()
            return .conditional(condition, then, otherwise)
        }
        return condition
    }

    private static let levels: [[CELExpression.BinaryOperator]] = [
        [.or],
        [.and],
        [.equal, .notEqual, .less, .lessOrEqual, .greater, .greaterOrEqual, .in],
        [.add, .subtract],
        [.multiply, .divide, .remainder],
    ]

    private func binaryOperator(at level: Int) -> CELExpression.BinaryOperator? {
        let candidates = Self.levels[level]
        switch peek {
        case .symbol(let symbol): return candidates.first { $0.rawValue == symbol }
        case .identifier("in"): return candidates.contains(.in) ? .in : nil
        default: return nil
        }
    }

    mutating func parseBinary(precedence level: Int) throws(CELError) -> CELExpression {
        guard level < Self.levels.count else { return try parseUnary() }
        var left = try parseBinary(precedence: level + 1)
        while let op = binaryOperator(at: level) {
            _ = advance()
            let right = try parseBinary(precedence: level + 1)
            left = .binary(op, left, right)
        }
        return left
    }

    mutating func parseUnary() throws(CELError) -> CELExpression {
        if consume("!") { return .unary(.not, try parseUnary()) }
        if consume("-") { return .unary(.negate, try parseUnary()) }
        return try parseMember()
    }

    mutating func parseMember() throws(CELError) -> CELExpression {
        var expression = try parsePrimary()
        while true {
            if consume(".") {
                guard case .identifier(let name) = advance() else { throw CELError("Expected a name after ‘.’") }
                if consume("(") {
                    expression = .member(expression, name: name, arguments: try parseArguments(closing: ")"))
                } else {
                    expression = .member(expression, name: name, arguments: nil)
                }
            } else if consume("[") {
                let index = try parseExpression()
                try expect("]")
                expression = .index(expression, index)
            } else {
                return expression
            }
        }
    }

    mutating func parseArguments(closing: String) throws(CELError) -> [CELExpression] {
        var arguments: [CELExpression] = []
        if consume(closing) { return arguments }
        repeat {
            if peek == .symbol(closing) { break } // trailing comma
            arguments.append(try parseExpression())
        } while consume(",")
        try expect(closing)
        return arguments
    }

    mutating func parsePrimary() throws(CELError) -> CELExpression {
        switch advance() {
        case .string(let value): return .literal(.string(value))
        case .int(let value): return .literal(.int(value))
        case .double(let value): return .literal(.double(value))
        case .identifier("true"): return .literal(.bool(true))
        case .identifier("false"): return .literal(.bool(false))
        case .identifier("null"): return .literal(.null)
        case .identifier(let name):
            if consume("(") {
                return .call(function: name, arguments: try parseArguments(closing: ")"))
            }
            return .identifier(name)
        case .symbol("("):
            let expression = try parseExpression()
            try expect(")")
            return expression
        case .symbol("["):
            return .list(try parseArguments(closing: "]"))
        case let token:
            throw CELError("Unexpected \(token) in filter")
        }
    }
}
