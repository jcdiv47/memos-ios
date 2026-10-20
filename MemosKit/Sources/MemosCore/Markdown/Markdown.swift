import Foundation

/// The block structure of a memo: what memos actually contain (headings, paragraphs, task and
/// bullet lists, quotes, code, tables), not all of CommonMark. Inline formatting inside each
/// block is left to `AttributedString(markdown:)` at render time.
public struct MarkdownDocument: Equatable, Sendable {
    public var blocks: [MarkdownBlock]

    public init(parsing content: String) {
        blocks = BlockParser(lines: content.components(separatedBy: "\n")).parse()
    }

    /// The text of the first heading when the memo opens with one. Shown as the memo's title.
    public var title: String? {
        if case .heading(_, let text) = blocks.first { return text }
        return nil
    }
}

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([ListItem])
    case quote(String)
    case code(language: String?, code: String)
    case table(header: [String], rows: [[String]])
    case rule
}

public struct ListItem: Equatable, Sendable {
    public enum Marker: Equatable, Sendable {
        case bullet
        case number(Int)
        case task(checked: Bool)
    }

    public var marker: Marker
    public var text: String
    /// Nesting depth, from indentation.
    public var depth: Int
    /// Zero-based line in the memo content, used to toggle a task in place.
    public var line: Int
}

struct BlockParser {
    let lines: [String]

    func parse() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let fence = Self.fence(trimmed) {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1 // closing fence
                blocks.append(.code(language: fence.language, code: code.joined(separator: "\n")))
                continue
            }

            if let (level, text) = Self.heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: level, text: text))
                index += 1
                continue
            }

            if Self.isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quote.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            if Self.listItem(line, line: index) != nil {
                flushParagraph()
                var items: [ListItem] = []
                while index < lines.count {
                    if let item = Self.listItem(lines[index], line: index) {
                        items.append(item)
                    } else if !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                              lines[index].hasPrefix("  "), !items.isEmpty {
                        // A continuation line belongs to the item above it.
                        items[items.count - 1].text += " " + lines[index].trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.list(items))
                continue
            }

            if trimmed.hasPrefix("|"), index + 1 < lines.count, Self.isTableDivider(lines[index + 1]) {
                flushParagraph()
                let header = Self.cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(Self.cells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    static func fence(_ line: String) -> (marker: String, language: String?)? {
        for marker in ["```", "~~~"] where line.hasPrefix(marker) {
            let language = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return (marker, language.isEmpty ? nil : language)
        }
        return nil
    }

    static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.count > hashes,
              line[line.index(line.startIndex, offsetBy: hashes)] == " "
        else { return nil }
        var text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") && text.dropLast().hasSuffix(" ") { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
        return (hashes, text)
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func listItem(_ line: String, line number: Int) -> ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        let depth = indent / 2

        var rest: Substring
        var marker: ListItem.Marker
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            rest = body.dropFirst(2)
            marker = .bullet
        } else {
            let digits = body.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let after = body.dropFirst(digits.count)
            guard let delimiter = after.first, delimiter == "." || delimiter == ")", after.dropFirst().first == " " else { return nil }
            rest = after.dropFirst(2)
            marker = .number(Int(digits) ?? 1)
        }

        if rest.hasPrefix("[ ] ") || rest == "[ ]" {
            marker = .task(checked: false)
            rest = rest.dropFirst(3)
        } else if rest.lowercased().hasPrefix("[x] ") || rest.lowercased() == "[x]" {
            marker = .task(checked: true)
            rest = rest.dropFirst(3)
        }
        return ListItem(marker: marker, text: rest.trimmingCharacters(in: .whitespaces), depth: depth, line: number)
    }

    static func isTableDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) } && trimmed.contains("-")
    }

    static func cells(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Analysis

/// What the server derives from a memo's content (`Memo.tags` and `Memo.property`), computed
/// on the device for memos edited offline so local filters see the same facts.
public struct ContentAnalysis: Equatable, Sendable {
    public var tags: [String]
    public var title: String
    public var hasLink: Bool
    public var hasCode: Bool
    public var hasTaskList: Bool
    public var hasIncompleteTasks: Bool

    public init(_ content: String) {
        let document = MarkdownDocument(parsing: content)
        var hasCode = false
        var hasTaskList = false
        var hasIncompleteTasks = false
        var prose: [String] = []
        for block in document.blocks {
            switch block {
            case .code:
                hasCode = true
            case .list(let items):
                for item in items {
                    if case .task(let checked) = item.marker {
                        hasTaskList = true
                        if !checked { hasIncompleteTasks = true }
                    }
                    prose.append(item.text)
                }
            case .heading(_, let text), .paragraph(let text), .quote(let text):
                prose.append(text)
            case .table(let header, let rows):
                prose.append(contentsOf: header)
                prose.append(contentsOf: rows.flatMap(\.self))
            case .rule:
                break
            }
        }
        let text = prose.joined(separator: "\n")
        let spans = TagScanner.codeSpans(in: text)
        if !spans.isEmpty { hasCode = true }
        self.tags = TagScanner.hierarchy(TagScanner.tags(in: text, excluding: spans))
        self.title = document.title ?? ""
        self.hasLink = TagScanner.containsLink(text)
        self.hasCode = hasCode
        self.hasTaskList = hasTaskList
        self.hasIncompleteTasks = hasIncompleteTasks
    }
}

/// Finds `#tags` in text following the server's rules closely enough for local filtering:
/// a tag starts after whitespace or punctuation, continues through letters, numbers, marks,
/// emoji and `_ - + &`, and nests with `/`.
public enum TagScanner {
    public struct Match: Equatable, Sendable {
        /// The tag without its `#`.
        public var tag: String
        /// Range of the whole `#tag` in the scanned string.
        public var range: Range<String.Index>
    }

    public static func matches(in text: String, excluding excluded: [Range<String.Index>] = []) -> [Match] {
        var matches: [Match] = []
        var index = text.startIndex
        var previous: Character?
        // Backslashes just before the current character; an odd count escapes it.
        var backslashes = 0
        while index < text.endIndex {
            let character = text[index]
            if character == "#", backslashes % 2 == 0, previous.map(isBoundary) ?? true,
               !excluded.contains(where: { $0.contains(index) }) {
                var end = text.index(after: index)
                var lastSegmentEnd = end
                while end < text.endIndex {
                    let next = text[end]
                    if isTagCharacter(next) {
                        end = text.index(after: end)
                        lastSegmentEnd = end
                    } else if next == "/" || next == "'" || next == "\u{2019}" {
                        let following = text.index(after: end)
                        guard following < text.endIndex, isTagCharacter(text[following]) else { break }
                        end = following
                    } else {
                        break
                    }
                }
                if lastSegmentEnd > text.index(after: index) {
                    let tag = String(text[text.index(after: index)..<lastSegmentEnd])
                    matches.append(Match(tag: tag, range: index..<lastSegmentEnd))
                    previous = text[text.index(before: lastSegmentEnd)]
                    backslashes = 0
                    index = lastSegmentEnd
                    continue
                }
            }
            backslashes = character == "\\" ? backslashes + 1 : 0
            previous = character
            index = text.index(after: index)
        }
        return matches
    }

    static func tags(in text: String, excluding spans: [Range<String.Index>]) -> [String] {
        matches(in: text, excluding: spans).map(\.tag)
    }

    /// Adds every ancestor of each nested tag and removes duplicates, keeping first-seen order.
    public static func hierarchy(_ tags: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for tag in tags {
            var prefix = ""
            for segment in tag.split(separator: "/") {
                prefix = prefix.isEmpty ? String(segment) : prefix + "/" + segment
                if seen.insert(prefix).inserted { result.append(prefix) }
            }
        }
        return result
    }

    static func isTagCharacter(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber || "_-+&".contains(character) { return true }
        if character.unicodeScalars.first?.properties.isEmojiPresentation == true { return true }
        return character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .nonspacingMark || $0.properties.generalCategory == .spacingMark }
    }

    static func isBoundary(_ character: Character) -> Bool {
        !(character.isLetter || character.isNumber || character == "_" || character == "#" || character == "&" || character == "/")
    }

    /// Ranges of inline `code` spans, where `#` never starts a tag.
    public static func codeSpans(in text: String) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "`" {
                if let open = start {
                    spans.append(open..<text.index(after: index))
                    start = nil
                } else {
                    start = index
                }
            } else if text[index] == "\n", start != nil {
                start = nil
            }
            index = text.index(after: index)
        }
        return spans
    }

    static func containsLink(_ text: String) -> Bool {
        if text.contains("](") { return true }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return false }
        return detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
