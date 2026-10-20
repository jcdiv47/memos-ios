import Foundation

/// What a run of highlighted code is.
public enum SyntaxTokenKind: String, Sendable, CaseIterable {
    case keyword
    /// Type names and built-in functions.
    case type
    case string
    case number
    case comment
    /// Decorators, annotations, preprocessor directives, Rust attributes and macros.
    case attribute
    /// Markup element names and CSS selectors.
    case tag
    /// JSON and YAML keys, markup attributes, CSS properties.
    case property
    /// Shell `$variables`, Ruby `@ivars`, YAML anchors.
    case variable
    case punctuation
}

public struct SyntaxToken: Equatable, Sendable {
    public var kind: SyntaxTokenKind
    /// Offsets into the code's UTF-8. Always on a character boundary.
    public var range: Range<Int>
}

/// A piece of the code with its kind, or nil for plain text. Together they make up the whole code.
public struct SyntaxSegment: Equatable, Sendable {
    public var text: String
    public var kind: SyntaxTokenKind?
}

/// Colours fenced code for the languages people paste into memos. It's a lexer, not a parser:
/// one forward pass over UTF-8 with constant lookahead, so time is linear in the code, and a
/// block longer than ``maximumLength`` stays plain. Every boundary it draws sits next to an
/// ASCII byte, so a range never splits a character.
public enum SyntaxHighlighter {
    /// Code longer than this, in UTF-8 bytes, isn't highlighted. Around 1,500 lines; past that,
    /// laying out the coloured text costs more than the colour is worth.
    public static let maximumLength = 64 * 1024

    public static func tokens(in code: String, language: String?) -> [SyntaxToken] {
        guard let language = language.flatMap(SyntaxLanguage.init(fenceInfo:)) else { return [] }
        return tokens(in: Array(code.utf8), language: language)
    }

    /// The code split into plain and highlighted pieces, ready to render.
    public static func segments(of code: String, language: String?) -> [SyntaxSegment] {
        guard let language = language.flatMap(SyntaxLanguage.init(fenceInfo:)) else {
            return code.isEmpty ? [] : [SyntaxSegment(text: code, kind: nil)]
        }
        let bytes = Array(code.utf8)
        var segments: [SyntaxSegment] = []
        var position = 0
        func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        for token in tokens(in: bytes, language: language) {
            if token.range.lowerBound > position {
                segments.append(SyntaxSegment(text: text(position..<token.range.lowerBound), kind: nil))
            }
            segments.append(SyntaxSegment(text: text(token.range), kind: token.kind))
            position = token.range.upperBound
        }
        if position < bytes.count {
            segments.append(SyntaxSegment(text: text(position..<bytes.count), kind: nil))
        }
        return segments
    }

    static func tokens(in bytes: [UInt8], language: SyntaxLanguage) -> [SyntaxToken] {
        guard !bytes.isEmpty, bytes.count <= maximumLength else { return [] }
        var lexer = CodeLexer(bytes: bytes)
        lexer.run(language.grammar, in: 0..<bytes.count)
        return lexer.tokens
    }
}

/// A language the highlighter knows, found from a fence's info string.
public struct SyntaxLanguage: Sendable {
    /// The canonical name: `swift`, `javascript`, `shell`…
    public let name: String
    let grammar: Grammar

    /// Reads the first word of a fence's info string (` ```py title="x" `), so `py`, `Python`
    /// and `python3` all find Python. Nil for a language without highlighting.
    public init?(fenceInfo: String) {
        let word = fenceInfo.prefix { !$0.isWhitespace && $0 != "{" && $0 != "," }.lowercased()
        guard let found = Self.aliases[word] else { return nil }
        self = found
    }

    private init(_ name: String, _ grammar: Grammar) {
        self.name = name
        self.grammar = grammar
    }

    private static let aliases: [String: SyntaxLanguage] = {
        var table: [String: SyntaxLanguage] = [:]
        func add(_ language: SyntaxLanguage, _ names: String) {
            table[language.name] = language
            for name in names.split(separator: " ") { table[String(name)] = language }
        }
        add(SyntaxLanguage("swift", .code(.swift)), "")
        add(SyntaxLanguage("python", .code(.python)), "py python3 py3 pyi gyp ipython")
        add(SyntaxLanguage("javascript", .code(.javascript)), "js jsx mjs cjs node")
        add(SyntaxLanguage("typescript", .code(.typescript)), "ts tsx mts cts")
        add(SyntaxLanguage("json", .code(.json)), "jsonc json5 geojson webmanifest")
        add(SyntaxLanguage("go", .code(.go)), "golang")
        add(SyntaxLanguage("rust", .code(.rust)), "rs")
        add(SyntaxLanguage("c", .code(.c)), "h")
        add(SyntaxLanguage("cpp", .code(.cpp)), "c++ cc cxx hpp hh hxx")
        add(SyntaxLanguage("objc", .code(.objc)), "objective-c objectivec obj-c objc++ objective-c++ m mm")
        add(SyntaxLanguage("java", .code(.java)), "")
        add(SyntaxLanguage("kotlin", .code(.kotlin)), "kt kts")
        add(SyntaxLanguage("ruby", .code(.ruby)), "rb gemfile podfile rake")
        add(SyntaxLanguage("shell", .code(.shell)), "sh bash zsh ksh fish console shellsession shell-session terminal")
        add(SyntaxLanguage("sql", .code(.sql)), "mysql postgresql postgres psql pgsql sqlite plsql tsql mssql mariadb")
        add(SyntaxLanguage("yaml", .yaml), "yml")
        add(SyntaxLanguage("html", .markup), "htm xhtml xml svg plist xsl xslt rss atom vue svelte")
        add(SyntaxLanguage("css", .css(lineComments: false)), "")
        add(SyntaxLanguage("scss", .css(lineComments: true)), "less sass")
        return table
    }()
}

enum Grammar: Sendable {
    case code(CodeRules)
    case yaml
    case markup
    case css(lineComments: Bool)
}

// MARK: - Rules

struct StringRule: Sendable {
    var open: [UInt8]
    var close: [UInt8]
    var escapes = true
    var multiline = false
    var kind = SyntaxTokenKind.string

    init(_ delimiter: String, escapes: Bool = true, multiline: Bool = false, kind: SyntaxTokenKind = .string) {
        open = Array(delimiter.utf8)
        close = open
        self.escapes = escapes
        self.multiline = multiline
        self.kind = kind
    }
}

struct BlockComment: Sendable {
    var open: [UInt8]
    var close: [UInt8]
    var nests = false
}

/// How a C-like, scripting or query language is lexed. Each flag is a construct only some
/// languages have.
struct CodeRules: Sendable {
    var keywords: Set<String> = []
    var types: Set<String> = []
    var lineComments: [[UInt8]] = []
    var blockComment: BlockComment?
    /// Checked in order, so triple quotes come before single ones.
    var strings: [StringRule] = []
    var caseInsensitive = false
    /// Capitalized identifiers are types (or classes, or constants).
    var capitalizedTypes = false
    /// Bytes allowed in identifiers besides letters, digits and `_`.
    var identifierExtras: [UInt8] = []
    /// `@Name` is an annotation or decorator.
    var annotations = false
    /// `#include` and friends at the start of a line.
    var preprocessor = false
    /// Swift `#if`, Rust `#[derive(…)]`.
    var hashAttributes = false
    /// Rust `'a`, as opposed to the character `'a'`.
    var lifetimes = false
    /// Rust `name!`.
    var macros = false
    /// Shell `$name`, `${…}`, `$1`.
    var dollarVariables = false
    /// Ruby `@name`, `@@name`.
    var instanceVariables = false
    /// Ruby `:name`.
    var symbols = false
    /// Python `f"…"`, `rb'…'`.
    var stringPrefixes: [UInt8] = []
    /// A string followed by `:` is a key (JSON).
    var keysBeforeColon = false
    /// The line comment starts only at the beginning of a word (the shell's `#`).
    var commentAtWordStart = false
}

private func words(_ list: String) -> Set<String> {
    Set(list.split(separator: " ").map(String.init))
}

private let slashComments: [[UInt8]] = [Array("//".utf8)]
private let cBlockComment = BlockComment(open: Array("/*".utf8), close: Array("*/".utf8))
private let cStrings = [StringRule("\""), StringRule("'")]

extension CodeRules {
    static let swift = CodeRules(
        keywords: words("""
        associatedtype class deinit enum extension fileprivate func import init inout internal let open operator \
        private precedencegroup protocol public rethrows static struct subscript typealias var break case catch \
        continue default defer do else fallthrough for guard if in repeat return throw switch where while as Any \
        await false is nil self Self super throws true try async actor nonisolated isolated some any consuming \
        borrowing mutating nonmutating override final required convenience lazy weak unowned dynamic indirect \
        optional get set willSet didSet package macro sending
        """),
        types: words("print debugPrint fatalError precondition assert min max abs zip stride type"),
        lineComments: slashComments,
        blockComment: BlockComment(open: Array("/*".utf8), close: Array("*/".utf8), nests: true),
        strings: [StringRule("\"\"\"", multiline: true), StringRule("\"")],
        capitalizedTypes: true,
        annotations: true,
        hashAttributes: true
    )

    static let python = CodeRules(
        keywords: words("""
        False None True and as assert async await break class continue def del elif else except finally for from \
        global if import in is lambda nonlocal not or pass raise return try while with yield match case self cls
        """),
        types: words("""
        int float str bool list dict set tuple bytes bytearray object type complex frozenset len range print \
        enumerate zip map filter isinstance issubclass super open sorted reversed min max sum abs any all iter next \
        repr hasattr getattr setattr callable round input format id hash vars dir
        """),
        lineComments: [Array("#".utf8)],
        strings: [
            StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true),
            StringRule("\""), StringRule("'"),
        ],
        capitalizedTypes: true,
        annotations: true,
        stringPrefixes: Array("rRbBfFuU".utf8)
    )

    static let javascript = CodeRules(
        keywords: words(javascriptKeywords),
        types: words(javascriptBuiltins),
        lineComments: slashComments,
        blockComment: cBlockComment,
        strings: [StringRule("`", multiline: true), StringRule("\""), StringRule("'")],
        capitalizedTypes: true,
        identifierExtras: Array("$".utf8),
        annotations: true
    )

    static let typescript: CodeRules = {
        var rules = javascript
        rules.keywords.formUnion(words("""
        interface type enum implements namespace declare abstract readonly private protected public keyof infer \
        is asserts satisfies module override unique
        """))
        rules.types.formUnion(words("string number boolean any unknown never void object symbol bigint"))
        return rules
    }()

    static let json = CodeRules(
        keywords: words("true false null"),
        lineComments: slashComments,
        blockComment: cBlockComment,
        strings: [StringRule("\"")],
        keysBeforeColon: true
    )

    static let go = CodeRules(
        keywords: words("""
        break case chan const continue default defer else fallthrough for func go goto if import interface map \
        package range return select struct switch type var true false nil iota
        """),
        types: words("""
        bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 \
        uint16 uint32 uint64 uintptr any comparable append cap close copy delete len make new panic print println \
        recover min max clear
        """),
        lineComments: slashComments,
        blockComment: cBlockComment,
        strings: [StringRule("`", escapes: false, multiline: true), StringRule("\""), StringRule("'")]
    )

    static let rust = CodeRules(
        keywords: words("""
        as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod \
        move mut pub ref return self Self static struct super trait true type unsafe use where while yield union
        """),
        types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
        lineComments: slashComments,
        blockComment: BlockComment(open: Array("/*".utf8), close: Array("*/".utf8), nests: true),
        strings: [StringRule("\"", multiline: true), StringRule("'")],
        capitalizedTypes: true,
        hashAttributes: true,
        lifetimes: true,
        macros: true
    )

    static let c = CodeRules(
        keywords: words(cKeywords),
        types: words(cTypes),
        lineComments: slashComments,
        blockComment: cBlockComment,
        strings: cStrings,
        preprocessor: true
    )

    static let cpp: CodeRules = {
        var rules = c
        rules.keywords.formUnion(words(cppKeywords))
        rules.types.formUnion(words("std string vector map unordered_map set unordered_set unique_ptr shared_ptr optional array pair"))
        return rules
    }()

    static let objc: CodeRules = {
        var rules = c
        rules.keywords.formUnion(words("""
        id self super nil Nil YES NO SEL IMP instancetype nonatomic atomic strong weak copy assign readonly \
        readwrite nullable nonnull __block __weak __strong in out
        """))
        rules.types.formUnion(words("BOOL NSInteger NSUInteger CGFloat"))
        rules.capitalizedTypes = true
        rules.annotations = true
        return rules
    }()

    static let java = CodeRules(
        keywords: words("""
        abstract assert boolean break byte case catch char class const continue default do double else enum \
        extends final finally float for goto if implements import instanceof int interface long native new \
        package private protected public return short static strictfp super switch synchronized this throw \
        throws transient try void volatile while var record sealed permits yield true false null
        """),
        lineComments: slashComments,
        blockComment: cBlockComment,
        strings: [StringRule("\"\"\"", multiline: true), StringRule("\""), StringRule("'")],
        capitalizedTypes: true,
        annotations: true
    )

    static let kotlin = CodeRules(
        keywords: words("""
        as break class continue do else false for fun if in interface is null object package return super this \
        throw true try typealias typeof val var when while by catch constructor init get set where actual \
        abstract annotation companion const crossinline data enum expect external final finally import infix \
        inline inner internal lateinit noinline open operator out override private protected public reified \
        sealed suspend tailrec vararg value
        """),
        types: words("println print listOf mapOf setOf mutableListOf mutableMapOf arrayOf lazy require check error"),
        lineComments: slashComments,
        blockComment: BlockComment(open: Array("/*".utf8), close: Array("*/".utf8), nests: true),
        strings: [StringRule("\"\"\"", escapes: false, multiline: true), StringRule("\""), StringRule("'")],
        capitalizedTypes: true,
        annotations: true
    )

    static let ruby = CodeRules(
        keywords: words("""
        BEGIN END alias and begin break case class def do else elsif end ensure false for if in module next nil \
        not or redo rescue retry return self super then true undef unless until when while yield __FILE__ \
        __LINE__ require require_relative attr_accessor attr_reader attr_writer include extend private protected \
        public lambda proc raise loop
        """),
        types: words("puts print p pp gets format sprintf"),
        lineComments: [Array("#".utf8)],
        strings: [
            StringRule("\"", multiline: true), StringRule("'", multiline: true), StringRule("`", multiline: true),
        ],
        capitalizedTypes: true,
        instanceVariables: true,
        symbols: true
    )

    static let shell = CodeRules(
        keywords: words("""
        if then else elif fi for while until do done case esac in function select time return break continue \
        exit local export readonly declare typeset unset shift source alias eval exec set trap wait
        """),
        types: words("echo printf read cd pwd pushd popd test true false kill jobs fg bg type command which sudo"),
        lineComments: [Array("#".utf8)],
        strings: [
            StringRule("\"", multiline: true), StringRule("'", escapes: false, multiline: true),
            StringRule("`", multiline: true),
        ],
        dollarVariables: true,
        commentAtWordStart: true
    )

    static let sql = CodeRules(
        keywords: words("""
        select from where insert into values update set delete create table drop alter add column index view \
        primary key foreign references unique not null default and or in is like ilike between exists join inner \
        left right outer full cross on as distinct group by order having limit offset union all case when then \
        else end asc desc if begin commit rollback transaction returning with recursive database schema grant \
        revoke truncate check constraint cascade replace explain analyze trigger procedure function return \
        returns declare true false over partition window using natural except intersect fetch first next rows only
        """),
        types: words("""
        int integer bigint smallint tinyint serial bigserial decimal numeric real float double precision char \
        varchar text boolean bool date time timestamp timestamptz interval json jsonb uuid blob bytea count sum \
        avg min max coalesce nullif now lower upper length cast row_number rank
        """),
        lineComments: [Array("--".utf8)],
        blockComment: cBlockComment,
        strings: [
            StringRule("'", escapes: false, multiline: true),
            StringRule("\"", escapes: false, kind: .property), StringRule("`", escapes: false, kind: .property),
        ],
        caseInsensitive: true
    )
}

private let javascriptKeywords = """
break case catch class const continue debugger default delete do else export extends finally for function if \
import in instanceof let new return super switch this throw try typeof var void while with yield async await of \
static get set null undefined true false NaN Infinity from as
"""

private let javascriptBuiltins = "console window document globalThis require module exports process"

private let cKeywords = """
auto break case char const continue default do double else enum extern float for goto if inline int long \
register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while \
_Bool _Complex bool true false NULL nullptr
"""

private let cTypes = """
size_t ssize_t ptrdiff_t intptr_t uintptr_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t \
wchar_t FILE printf fprintf sprintf snprintf malloc calloc realloc free memcpy memset strlen
"""

private let cppKeywords = """
alignas alignof and asm catch class constexpr consteval constinit decltype delete explicit export friend mutable \
namespace new noexcept not operator or override private protected public static_assert template this \
thread_local throw try typeid typename using virtual co_await co_return co_yield concept requires final
"""

private let yamlKeywords = words("true false yes no on off null ~")
private let cssLineComment = Array("//".utf8)

// MARK: - Lexer

private extension UInt8 {
    static let newline = UInt8(ascii: "\n")

    var isDigit: Bool { self >= 0x30 && self <= 0x39 }
    var isLetter: Bool { (self | 0x20) >= 0x61 && (self | 0x20) <= 0x7A }
    var isUppercase: Bool { self >= 0x41 && self <= 0x5A }
    /// Space within a line.
    var isSpace: Bool { self == 0x20 || self == 0x09 || self == 0x0D || self == 0x0C }
    var isSpaceOrNewline: Bool { isSpace || self == .newline }
    /// Letters, digits, `_` and any non-ASCII byte, so a word never ends inside a character.
    var isWordByte: Bool { isLetter || isDigit || self == 0x5F || self >= 0x80 }
    var startsWord: Bool { isLetter || self == 0x5F || self >= 0x80 }
    var isPunctuation: Bool { self > 0x20 && self < 0x7F && !isLetter && !isDigit && self != 0x5F }
}

private func ascii(_ character: Unicode.Scalar) -> UInt8 { UInt8(ascii: character) }

struct CodeLexer {
    let bytes: [UInt8]
    var tokens: [SyntaxToken] = []

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func run(_ grammar: Grammar, in range: Range<Int>) {
        switch grammar {
        case .code(let rules): code(rules, in: range)
        case .yaml: yaml(in: range)
        case .markup: markup(in: range)
        case .css(let lineComments): css(lineComments: lineComments, in: range)
        }
    }

    // MARK: Helpers

    private mutating func emit(_ kind: SyntaxTokenKind, _ range: Range<Int>) {
        guard !range.isEmpty else { return }
        // Runs of punctuation make one token, so `->` or `});` doesn't cost a token per byte.
        if kind == .punctuation, let last = tokens.last, last.kind == .punctuation, last.range.upperBound == range.lowerBound {
            tokens[tokens.count - 1].range = last.range.lowerBound..<range.upperBound
        } else {
            tokens.append(SyntaxToken(kind: kind, range: range))
        }
    }

    /// The byte at `index`, or 0 past `end`.
    private func byte(_ index: Int, _ end: Int) -> UInt8 {
        index < end ? bytes[index] : 0
    }

    private func matches(_ pattern: [UInt8], at index: Int, _ end: Int) -> Bool {
        guard index + pattern.count <= end else { return false }
        for offset in pattern.indices where bytes[index + offset] != pattern[offset] { return false }
        return true
    }

    private func matchesIgnoringCase(_ pattern: [UInt8], at index: Int, _ end: Int) -> Bool {
        guard index + pattern.count <= end else { return false }
        for offset in pattern.indices where bytes[index + offset] | 0x20 != pattern[offset] | 0x20 { return false }
        return true
    }

    private func lineEnd(from index: Int, _ end: Int) -> Int {
        var index = index
        while index < end, bytes[index] != .newline { index += 1 }
        return index
    }

    private func skipSpaces(from index: Int, _ end: Int) -> Int {
        var index = index
        while index < end, bytes[index].isSpace { index += 1 }
        return index
    }

    private func wordEnd(from index: Int, _ end: Int, extras: [UInt8] = []) -> Int {
        var index = index
        while index < end, bytes[index].isWordByte || extras.contains(bytes[index]) { index += 1 }
        return index
    }

    /// Where `pattern` next occurs, or `end`.
    private func find(_ pattern: [UInt8], from index: Int, _ end: Int, ignoringCase: Bool = false) -> Int {
        var index = index
        while index < end {
            if bytes[index] | (ignoringCase ? 0x20 : 0) == pattern[0] | (ignoringCase ? 0x20 : 0),
               ignoringCase ? matchesIgnoringCase(pattern, at: index, end) : matches(pattern, at: index, end) {
                return index
            }
            index += 1
        }
        return end
    }

    private func stringEnd(_ rule: StringRule, from index: Int, _ end: Int) -> Int {
        var index = index
        while index < end {
            let current = bytes[index]
            if rule.escapes && current == ascii("\\") {
                index += 2
                continue
            }
            if current == rule.close[0], matches(rule.close, at: index, end) { return index + rule.close.count }
            // An unclosed one-line string stops at the line's end rather than colouring the rest.
            if current == .newline && !rule.multiline { return index }
            index += 1
        }
        return end
    }

    private func blockCommentEnd(_ comment: BlockComment, from index: Int, _ end: Int) -> Int {
        var index = index
        var depth = 1
        while index < end {
            if comment.nests, matches(comment.open, at: index, end) {
                depth += 1
                index += comment.open.count
            } else if matches(comment.close, at: index, end) {
                depth -= 1
                index += comment.close.count
                if depth == 0 { return index }
            } else {
                index += 1
            }
        }
        return end
    }

    private func numberEnd(from start: Int, _ end: Int) -> Int {
        let hex = bytes[start] == ascii("0") && byte(start + 1, end) | 0x20 == ascii("x")
        var index = start + 1
        while index < end {
            let current = bytes[index]
            if current.isLetter || current.isDigit || current == ascii("_") {
                index += 1
            } else if current == ascii("."), byte(index + 1, end).isDigit {
                // Not `1..<5`: a dot joins the number only before a digit.
                index += 1
            } else if current == ascii("+") || current == ascii("-"), !hex, bytes[index - 1] | 0x20 == ascii("e"), byte(index + 1, end).isDigit {
                index += 1
            } else {
                break
            }
        }
        return index
    }

    /// Whether a number starts here: a digit, or `.5` not following a word or another dot.
    private func startsNumber(at index: Int, in range: Range<Int>) -> Bool {
        let current = bytes[index]
        if current.isDigit { return true }
        guard current == ascii("."), byte(index + 1, range.upperBound).isDigit else { return false }
        guard index > range.lowerBound else { return true }
        let previous = bytes[index - 1]
        return !previous.isWordByte && previous != ascii(".")
    }

    // MARK: Code

    private mutating func code(_ rules: CodeRules, in range: Range<Int>) {
        let end = range.upperBound
        var index = range.lowerBound
        var atLineStart = true
        let maxKeywordLength = 24

        while index < end {
            let current = bytes[index]
            if current == .newline {
                atLineStart = true
                index += 1
                continue
            }
            if current.isSpace {
                index += 1
                continue
            }
            let lineStart = atLineStart
            atLineStart = false
            let start = index
            let next = byte(index + 1, end)

            if let comment = rules.blockComment, matches(comment.open, at: index, end) {
                index = blockCommentEnd(comment, from: index + comment.open.count, end)
                emit(.comment, start..<index)
                continue
            }

            if rules.lineComments.contains(where: { matches($0, at: index, end) }),
               !rules.commentAtWordStart || index == range.lowerBound || bytes[index - 1].isSpaceOrNewline {
                index = lineEnd(from: index, end)
                emit(.comment, start..<index)
                continue
            }

            if rules.lifetimes, current == ascii("'"), next.isLetter || next == ascii("_"), byte(index + 2, end) != ascii("'") {
                index = wordEnd(from: index + 1, end)
                emit(.attribute, start..<index)
                continue
            }

            if let rule = rules.strings.first(where: { matches($0.open, at: index, end) }) {
                index = stringEnd(rule, from: index + rule.open.count, end)
                let isKey = rules.keysBeforeColon && byte(skipSpaces(from: index, end), end) == ascii(":")
                emit(isKey ? .property : rule.kind, start..<index)
                continue
            }

            if rules.preprocessor, lineStart, current == ascii("#") {
                let nameStart = skipSpaces(from: index + 1, end)
                index = wordEnd(from: nameStart, end)
                emit(.attribute, start..<index)
                // `#include <stdio.h>`: the header is a string.
                let directive = String(decoding: bytes[nameStart..<index], as: UTF8.self)
                let target = skipSpaces(from: index, end)
                if directive == "include" || directive == "import", byte(target, end) == ascii("<") {
                    var close = target + 1
                    while close < end, bytes[close] != ascii(">"), bytes[close] != .newline { close += 1 }
                    if byte(close, end) == ascii(">") {
                        index = close + 1
                        emit(.string, target..<index)
                    }
                }
                continue
            }

            if rules.hashAttributes, current == ascii("#") {
                if next == ascii("[") || (next == ascii("!") && byte(index + 2, end) == ascii("[")) {
                    // `#[derive(Debug)]`, to its closing bracket on the same line.
                    var depth = 0
                    index += 1
                    while index < end, bytes[index] != .newline {
                        if bytes[index] == ascii("[") { depth += 1 }
                        if bytes[index] == ascii("]") {
                            depth -= 1
                            if depth == 0 {
                                index += 1
                                break
                            }
                        }
                        index += 1
                    }
                    emit(.attribute, start..<index)
                    continue
                }
                if next.startsWord {
                    index = wordEnd(from: index + 1, end)
                    emit(.attribute, start..<index)
                    continue
                }
            }

            if rules.annotations, current == ascii("@"), next.startsWord {
                index = wordEnd(from: index + 1, end)
                // `@objc.name`, `@pytest.mark.slow`
                while byte(index, end) == ascii("."), byte(index + 1, end).startsWord {
                    index = wordEnd(from: index + 1, end)
                }
                emit(.attribute, start..<index)
                continue
            }

            if rules.instanceVariables, current == ascii("@") {
                let nameStart = next == ascii("@") ? index + 2 : index + 1
                if byte(nameStart, end).startsWord {
                    index = wordEnd(from: nameStart, end)
                    emit(.variable, start..<index)
                    continue
                }
            }

            if rules.dollarVariables, current == ascii("$") {
                if next == ascii("{") {
                    index += 2
                    while index < end, bytes[index] != ascii("}"), bytes[index] != .newline { index += 1 }
                    if byte(index, end) == ascii("}") { index += 1 }
                    emit(.variable, start..<index)
                    continue
                }
                if next.startsWord {
                    index = wordEnd(from: index + 1, end)
                    emit(.variable, start..<index)
                    continue
                }
                if next.isDigit || "#?@*!$-".utf8.contains(next) {
                    index += 2
                    emit(.variable, start..<index)
                    continue
                }
            }

            if rules.symbols, current == ascii(":"), next.isLetter || next == ascii("_"),
               index == range.lowerBound || (bytes[index - 1] != ascii(":") && !bytes[index - 1].isWordByte) {
                index = wordEnd(from: index + 1, end)
                emit(.attribute, start..<index)
                continue
            }

            if startsNumber(at: index, in: range) {
                index = numberEnd(from: index, end)
                emit(.number, start..<index)
                continue
            }

            if current.startsWord || rules.identifierExtras.contains(current) {
                index = wordEnd(from: index, end, extras: rules.identifierExtras)

                if !rules.stringPrefixes.isEmpty, index - start <= 2,
                   bytes[start..<index].allSatisfy(rules.stringPrefixes.contains),
                   let rule = rules.strings.first(where: { matches($0.open, at: index, end) }) {
                    index = stringEnd(rule, from: index + rule.open.count, end)
                    emit(.string, start..<index)
                    continue
                }

                if rules.macros, byte(index, end) == ascii("!"), byte(index + 1, end) != ascii("=") {
                    index += 1
                    emit(.attribute, start..<index)
                    continue
                }

                if index - start <= maxKeywordLength {
                    var word = String(decoding: bytes[start..<index], as: UTF8.self)
                    if rules.caseInsensitive { word = word.lowercased() }
                    if rules.keywords.contains(word) {
                        emit(.keyword, start..<index)
                        continue
                    }
                    if rules.types.contains(word) {
                        emit(.type, start..<index)
                        continue
                    }
                }
                if rules.capitalizedTypes, current.isUppercase {
                    emit(.type, start..<index)
                }
                continue
            }

            if current.isPunctuation {
                emit(.punctuation, start..<start + 1)
            }
            index += 1
        }
    }

    // MARK: YAML

    private mutating func yaml(in range: Range<Int>) {
        let end = range.upperBound
        var index = range.lowerBound
        // The indentation of the line that opened a `|` or `>` block, whose deeper lines are text.
        var blockIndent: Int?

        while index < end {
            let lineStart = index
            var content = index
            while content < end, bytes[content] == ascii(" ") || bytes[content] == ascii("\t") { content += 1 }
            let indent = content - lineStart
            let eol = lineEnd(from: content, end)
            defer { index = eol + 1 }

            if let block = blockIndent {
                if content == eol { continue }
                if indent > block {
                    emit(.string, content..<eol)
                    continue
                }
                blockIndent = nil
            }

            var position = content
            if matches(Array("---".utf8), at: content, end) || matches(Array("...".utf8), at: content, end),
               content + 3 == eol || bytes[content + 3].isSpace {
                emit(.punctuation, content..<content + 3)
                position = content + 3
            }
            if yamlLine(from: position, to: eol, lineStart: content) {
                blockIndent = indent
            }
        }
    }

    /// Lexes one line of YAML. Returns whether it opens a block scalar.
    private mutating func yamlLine(from start: Int, to eol: Int, lineStart: Int) -> Bool {
        var index = start
        var flowDepth = 0
        var opensBlock = false

        while index < eol {
            let current = bytes[index]
            if current.isSpace {
                index += 1
                continue
            }
            let tokenStart = index
            let next = byte(index + 1, eol)
            let followedBySpace = index + 1 == eol || next.isSpace

            if current == ascii("#"), index == lineStart || bytes[index - 1].isSpace {
                emit(.comment, index..<eol)
                return opensBlock
            }
            if current == ascii("\"") || current == ascii("'") {
                index = stringEnd(StringRule(current == ascii("\"") ? "\"" : "'", escapes: current == ascii("\"")), from: index + 1, eol)
                emit(byte(skipSpaces(from: index, eol), eol) == ascii(":") ? .property : .string, tokenStart..<index)
                continue
            }
            if current == ascii("-") && followedBySpace || current == ascii(":") && followedBySpace || current == ascii(",") {
                emit(.punctuation, index..<index + 1)
                index += 1
                continue
            }
            if current == ascii("[") || current == ascii("{") || current == ascii("]") || current == ascii("}") {
                flowDepth += current == ascii("[") || current == ascii("{") ? 1 : -1
                emit(.punctuation, index..<index + 1)
                index += 1
                continue
            }
            if current == ascii("&") || current == ascii("*") || current == ascii("!"), !followedBySpace {
                index += 1
                while index < eol, !bytes[index].isSpace, !",[]{}".utf8.contains(bytes[index]) { index += 1 }
                emit(current == ascii("!") ? .attribute : .variable, tokenStart..<index)
                continue
            }
            if current == ascii("|") || current == ascii(">") {
                var indicatorEnd = index + 1
                while indicatorEnd < eol, bytes[indicatorEnd] == ascii("+") || bytes[indicatorEnd] == ascii("-") || bytes[indicatorEnd].isDigit {
                    indicatorEnd += 1
                }
                let after = skipSpaces(from: indicatorEnd, eol)
                if after == eol || bytes[after] == ascii("#") {
                    emit(.punctuation, index..<indicatorEnd)
                    opensBlock = true
                    index = indicatorEnd
                    continue
                }
            }

            // A plain scalar, up to `: `, ` #`, or a flow indicator inside `[…]` or `{…}`.
            var scalarEnd = index
            while scalarEnd < eol {
                let byte = bytes[scalarEnd]
                if byte == ascii(":"), scalarEnd + 1 == eol || bytes[scalarEnd + 1].isSpace { break }
                if byte == ascii("#"), scalarEnd > index, bytes[scalarEnd - 1].isSpace { break }
                if flowDepth > 0, ",[]{}".utf8.contains(byte) { break }
                scalarEnd += 1
            }
            var trimmedEnd = scalarEnd
            while trimmedEnd > index, bytes[trimmedEnd - 1].isSpace { trimmedEnd -= 1 }
            if scalarEnd < eol, bytes[scalarEnd] == ascii(":") {
                emit(.property, index..<trimmedEnd)
            } else if trimmedEnd - index <= 5, yamlKeywords.contains(String(decoding: bytes[index..<trimmedEnd], as: UTF8.self).lowercased()) {
                emit(.keyword, index..<trimmedEnd)
            } else if isYAMLNumber(index..<trimmedEnd) {
                emit(.number, index..<trimmedEnd)
            }
            index = scalarEnd
        }
        return opensBlock
    }

    private func isYAMLNumber(_ range: Range<Int>) -> Bool {
        guard let first = range.first.map({ bytes[$0] }) else { return false }
        let leadsWithDigit = first.isDigit || (range.count > 1 && "+-.".utf8.contains(first) && bytes[range.lowerBound + 1].isDigit)
        return leadsWithDigit && bytes[range].allSatisfy { $0.isDigit || "._+-:eE".utf8.contains($0) }
    }

    // MARK: Markup

    private mutating func markup(in range: Range<Int>) {
        let end = range.upperBound
        var index = range.lowerBound

        while index < end {
            let current = bytes[index]
            let next = byte(index + 1, end)
            let start = index

            if current == ascii("<") {
                if matches(Array("<!--".utf8), at: index, end) {
                    let close = find(Array("-->".utf8), from: index + 4, end)
                    index = min(close + 3, end)
                    emit(.comment, start..<index)
                    continue
                }
                if matches(Array("<![CDATA[".utf8), at: index, end) {
                    let close = find(Array("]]>".utf8), from: index + 9, end)
                    index = min(close + 3, end)
                    emit(.string, start..<index)
                    continue
                }
                if next == ascii("!") || next == ascii("?") {
                    emit(.punctuation, index..<index + 2)
                    index = tag(from: index + 2, end, nameKind: .keyword).end
                    continue
                }
                if next == ascii("/"), byte(index + 2, end).isLetter {
                    emit(.punctuation, index..<index + 2)
                    index = tag(from: index + 2, end, nameKind: .tag).end
                    continue
                }
                if next.isLetter {
                    emit(.punctuation, index..<index + 1)
                    let opened = tag(from: index + 1, end, nameKind: .tag)
                    index = opened.end
                    // Scripts and styles inside the page are coloured as what they are.
                    let embedded: Grammar? = switch opened.name.lowercased() {
                    case "script": .code(.javascript)
                    case "style": .css(lineComments: false)
                    default: nil
                    }
                    if let embedded, !opened.selfClosing {
                        let close = find(Array("</\(opened.name.lowercased())".utf8), from: index, end, ignoringCase: true)
                        run(embedded, in: index..<close)
                        index = close
                    }
                    continue
                }
            }

            if current == ascii("&") {
                var entityEnd = index + 1
                while entityEnd < end, entityEnd - index < 12, bytes[entityEnd].isLetter || bytes[entityEnd].isDigit || bytes[entityEnd] == ascii("#") {
                    entityEnd += 1
                }
                if byte(entityEnd, end) == ascii(";"), entityEnd > index + 1 {
                    index = entityEnd + 1
                    emit(.attribute, start..<index)
                    continue
                }
            }
            index += 1
        }
    }

    /// Lexes a tag from its name to its `>`.
    private mutating func tag(from start: Int, _ end: Int, nameKind: SyntaxTokenKind) -> (end: Int, name: String, selfClosing: Bool) {
        let isNameByte = { (byte: UInt8) in byte.isWordByte || byte == ascii("-") || byte == ascii(":") || byte == ascii(".") }
        var index = start
        while index < end, isNameByte(bytes[index]) { index += 1 }
        emit(nameKind, start..<index)
        let name = String(decoding: bytes[start..<index], as: UTF8.self)

        while index < end {
            let current = bytes[index]
            if current.isSpaceOrNewline {
                index += 1
            } else if current == ascii(">") {
                emit(.punctuation, index..<index + 1)
                return (index + 1, name, false)
            } else if (current == ascii("/") || current == ascii("?")), byte(index + 1, end) == ascii(">") {
                emit(.punctuation, index..<index + 2)
                return (index + 2, name, current == ascii("/"))
            } else if current == ascii("<") {
                // Unclosed tag: let the next one start here.
                return (index, name, false)
            } else if current == ascii("=") {
                emit(.punctuation, index..<index + 1)
                index += 1
            } else if current == ascii("\"") || current == ascii("'") {
                let valueStart = index
                index = stringEnd(StringRule(current == ascii("\"") ? "\"" : "'", escapes: false, multiline: true), from: index + 1, end)
                emit(.string, valueStart..<index)
            } else if isNameByte(current) {
                let attributeStart = index
                while index < end, isNameByte(bytes[index]) { index += 1 }
                // An unquoted value follows `=`; anything else is an attribute name.
                let isValue = attributeStart > start && bytes[attributeStart - 1] == ascii("=")
                emit(isValue ? .string : .property, attributeStart..<index)
            } else {
                index += 1
            }
        }
        return (end, name, false)
    }

    // MARK: CSS

    private mutating func css(lineComments: Bool, in range: Range<Int>) {
        let end = range.upperBound
        var index = range.lowerBound
        // After a property's colon, until `;` or a brace.
        var inValue = false
        let isNameByte = { (byte: UInt8) in byte.isWordByte || byte == ascii("-") }

        while index < end {
            let current = bytes[index]
            let next = byte(index + 1, end)
            let start = index

            if current.isSpaceOrNewline {
                index += 1
                continue
            }
            if matches(cBlockComment.open, at: index, end) {
                index = blockCommentEnd(cBlockComment, from: index + 2, end)
                emit(.comment, start..<index)
                continue
            }
            // Not in a value, where `url(//cdn…)` would look like one.
            if lineComments, !inValue, matches(cssLineComment, at: index, end) {
                index = lineEnd(from: index, end)
                emit(.comment, start..<index)
                continue
            }
            if current == ascii("\"") || current == ascii("'") {
                index = stringEnd(StringRule(current == ascii("\"") ? "\"" : "'"), from: index + 1, end)
                emit(.string, start..<index)
                continue
            }
            if current == ascii("{") || current == ascii("}") || current == ascii(";") {
                inValue = false
                emit(.punctuation, index..<index + 1)
                index += 1
                continue
            }
            if current == ascii("@"), next.startsWord {
                index = wordEnd(from: index + 1, end, extras: [ascii("-")])
                emit(.keyword, start..<index)
                continue
            }
            if current == ascii("!"), matchesIgnoringCase(Array("important".utf8), at: index + 1, end) {
                index += 10
                emit(.keyword, start..<index)
                continue
            }
            if current == ascii("#"), isNameByte(next) {
                index = wordEnd(from: index + 1, end, extras: [ascii("-")])
                // A colour in a value; an ID in a selector.
                emit(inValue ? .number : .attribute, start..<index)
                continue
            }
            if !inValue, current == ascii("."), next.startsWord || next == ascii("-") {
                index = wordEnd(from: index + 1, end, extras: [ascii("-")])
                emit(.attribute, start..<index)
                continue
            }
            if !inValue, current == ascii(":") {
                // `:hover`, `::before`
                var nameStart = index + 1
                if byte(nameStart, end) == ascii(":") { nameStart += 1 }
                if byte(nameStart, end).startsWord {
                    emit(.punctuation, index..<nameStart)
                    index = wordEnd(from: nameStart, end, extras: [ascii("-")])
                    emit(.keyword, nameStart..<index)
                    continue
                }
            }
            if startsNumber(at: index, in: range) {
                index = numberEnd(from: index, end)
                emit(.number, start..<index)
                continue
            }
            if current.startsWord || (current == ascii("-") && (next.startsWord || next == ascii("-"))) {
                index = wordEnd(from: index + 1, end, extras: [ascii("-")])
                let colon = skipSpaces(from: index, end)
                if !inValue, byte(colon, end) == ascii(":") {
                    // `color: red` is a declaration; `a:hover` is a selector.
                    let afterColon = byte(colon + 1, end)
                    if !afterColon.startsWord || bytes[start] == ascii("-") {
                        emit(.property, start..<index)
                        emit(.punctuation, colon..<colon + 1)
                        inValue = true
                        index = colon + 1
                        continue
                    }
                }
                if !inValue { emit(.tag, start..<index) }
                continue
            }
            if current.isPunctuation {
                emit(.punctuation, index..<index + 1)
            }
            index += 1
        }
    }
}
