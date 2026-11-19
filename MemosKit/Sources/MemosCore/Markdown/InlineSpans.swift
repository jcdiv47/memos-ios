import Foundation

/// The parts of a line of inline Markdown whose text is taken literally: `code` spans and
/// `$math$`. A `#` inside either never starts a tag, and Markdown never touches their text.
///
/// Math follows the server's parser (`markdown/parser/math.go`): a run of `$` opens and the
/// next run of exactly the same length closes, across lines but not across a blank line. A
/// single `$` must be followed by a non-space to open, and closes only after a non-space and
/// before a non-digit, so `$20,000 and $30,000` stays text. An escaped `\$` is a dollar sign.
public enum InlineSpans {
    public enum Kind: Equatable, Sendable {
        case code
        case math
    }

    public struct Span: Equatable, Sendable {
        public var kind: Kind
        /// The whole span, delimiters included.
        public var range: Range<String.Index>
    }

    public static func scan(_ text: String) -> [Span] {
        var spans: [Span] = []
        var index = text.startIndex
        // Backslashes just before the current character; an odd count escapes it.
        var backslashes = 0
        while index < text.endIndex {
            let character = text[index]
            if character == "`", let close = closingBacktick(in: text, after: index) {
                let end = text.index(after: close)
                spans.append(Span(kind: .code, range: index..<end))
                index = end
                backslashes = 0
                continue
            }
            if character == "$" {
                if backslashes % 2 == 1 {
                    // `\$` is a literal dollar; a run can still open right after it.
                    index = text.index(after: index)
                    backslashes = 0
                    continue
                }
                let opening = dollarRunEnd(in: text, from: index)
                if let end = mathEnd(in: text, opening: index..<opening) {
                    spans.append(Span(kind: .math, range: index..<end))
                    index = end
                } else {
                    // A run that doesn't open math never opens part-way through.
                    index = opening
                }
                backslashes = 0
                continue
            }
            backslashes = character == "\\" ? backslashes + 1 : 0
            index = text.index(after: index)
        }
        return spans
    }

    /// The next backtick on the same line.
    private static func closingBacktick(in text: String, after open: String.Index) -> String.Index? {
        var index = text.index(after: open)
        while index < text.endIndex {
            switch text[index] {
            case "`": return index
            case "\n": return nil
            default: index = text.index(after: index)
            }
        }
        return nil
    }

    private static func dollarRunEnd(in text: String, from start: String.Index) -> String.Index {
        var end = start
        while end < text.endIndex, text[end] == "$" { end = text.index(after: end) }
        return end
    }

    private static func mathEnd(in text: String, opening: Range<String.Index>) -> String.Index? {
        let length = text.distance(from: opening.lowerBound, to: opening.upperBound)
        if length == 1 {
            guard opening.upperBound < text.endIndex, !text[opening.upperBound].isWhitespace else { return nil }
        }
        var index = opening.upperBound
        while index < text.endIndex {
            let character = text[index]
            if character == "\n" {
                if startsBlankLine(in: text, after: index) { return nil }
                index = text.index(after: index)
                continue
            }
            guard character == "$" else {
                index = text.index(after: index)
                continue
            }
            let end = dollarRunEnd(in: text, from: index)
            if text.distance(from: index, to: end) == length {
                // The first run of the same length decides: if a single `$` can't close here,
                // the opening one is just a dollar sign.
                if length == 1 {
                    let before = text[text.index(before: index)]
                    guard !before.isWhitespace else { return nil }
                    if end < text.endIndex, let after = text[end].asciiValue, (0x30...0x39).contains(after) { return nil }
                }
                return end
            }
            index = end
        }
        return nil
    }

    /// Whether the line after the newline at `newline` is empty or only whitespace: the end of
    /// a paragraph, which inline math doesn't cross.
    private static func startsBlankLine(in text: String, after newline: String.Index) -> Bool {
        var index = text.index(after: newline)
        while index < text.endIndex, text[index] != "\n" {
            guard text[index].isWhitespace else { return false }
            index = text.index(after: index)
        }
        return true
    }
}

/// Inline Markdown parsed by Foundation, with what Foundation would get wrong fixed first.
public enum InlineParsing {
    /// `AttributedString(markdown:)` for one block's text, with `$math$` kept exactly as written,
    /// marked as code and with its TeX in ``InlineMathAttribute``, and escaped hashes marked as in
    /// ``markingEscapedHashes(_:)``.
    ///
    /// Foundation doesn't know math: `$a*b*c$` would lose its asterisks to emphasis and
    /// `$\{x\}$` its backslashes. Each math span is swapped for a private-use character before
    /// parsing, so emphasis or a link around it still applies, and swapped back after.
    public static func attributed(_ text: String) -> AttributedString {
        let math = InlineSpans.scan(text).filter { $0.kind == .math }.map(\.range)
        var source = text
        var protected: [Substring] = []
        if !math.isEmpty, math.count <= placeholderCount, !text.unicodeScalars.contains(where: isPlaceholder) {
            source = ""
            var last = text.startIndex
            for range in math {
                source += text[last..<range.lowerBound]
                source.unicodeScalars.append(placeholder(protected.count))
                protected.append(text[range])
                last = range.upperBound
            }
            source += text[last...]
        }

        var attributed = (try? AttributedString(
            markdown: markingEscapedHashes(source),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)

        for (offset, tex) in protected.enumerated().reversed() {
            guard let range = attributed.range(of: String(Character(placeholder(offset)))) else { continue }
            var piece = AttributedString(String(tex), attributes: attributed[range].runs.first?.attributes ?? AttributeContainer())
            piece.inlinePresentationIntent = (piece.inlinePresentationIntent ?? []).union(.code)
            let fence = tex.prefix { $0 == "$" }.count
            piece[InlineMathAttribute.self] = String(tex.dropFirst(fence).dropLast(fence))
            attributed.replaceSubrange(range, with: piece)
        }
        return attributed
    }

    /// `\#13-04` renders as `#13-04` but isn't a tag. Parsing drops the backslash, so the `#` is
    /// followed by an invisible word joiner instead, which no tag can start with.
    public static func markingEscapedHashes(_ text: String) -> String {
        guard text.contains("\\#") else { return text }
        var result = ""
        var backslashes = 0
        for character in text {
            if character == "#", backslashes % 2 == 1 {
                result.removeLast()
                result += "#\u{2060}"
            } else {
                result.append(character)
            }
            backslashes = character == "\\" ? backslashes + 1 : 0
        }
        return result
    }

    // Supplementary Private Use Area-A: nothing a memo would contain, and one character each.
    private static let placeholderBase: UInt32 = 0xF0000
    private static let placeholderCount = 0xFFFE

    private static func placeholder(_ offset: Int) -> Unicode.Scalar {
        Unicode.Scalar(placeholderBase + UInt32(offset))!
    }

    private static func isPlaceholder(_ scalar: Unicode.Scalar) -> Bool {
        (placeholderBase..<placeholderBase + UInt32(placeholderCount)).contains(scalar.value)
    }
}

/// The TeX of an inline math run, without its dollar signs, for typesetting it.
public enum InlineMathAttribute: AttributedStringKey {
    public typealias Value = String
    public static let name = "memos.inlineMath"
}
