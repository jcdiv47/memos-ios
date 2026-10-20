import Foundation

/// One replacement in a text, with ranges in UTF-16 offsets as `UITextView` and `NSString` count
/// them. The composer applies it through the text view, so it can be undone.
public struct TextEdit: Equatable, Sendable {
    /// What to replace, in the text before the edit.
    public var range: NSRange
    public var replacement: String
    /// The selection afterwards.
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

/// The composer's formatting actions.
public enum MarkdownFormat: CaseIterable, Sendable {
    case bold, italic, strikethrough, code
    case heading1, heading2, heading3
    case bulletList, numberedList, taskList, quote
    case link, codeBlock
}

/// A `#tag` being typed: the whole token, and the part of it before the cursor.
public struct TagToken: Equatable, Sendable {
    public var range: NSRange
    public var prefix: String

    public init(range: NSRange, prefix: String) {
        self.range = range
        self.prefix = prefix
    }
}

/// Rewrites of memo text for the composer and for tapping a task. Everything here is plain text
/// in, edit out, so it can be tested away from UIKit.
public enum MarkdownEditing {
    /// Flips the task checkbox on `line`, the same rewrite of the memo content the web makes.
    /// Returns the content unchanged when that line holds no task.
    public static func toggleTask(atLine line: Int, in content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard lines.indices.contains(line), let item = BlockParser.listItem(lines[line], line: line),
              case .task(let checked) = item.marker,
              let range = lines[line].range(of: checked ? "[x]" : "[ ]", options: checked ? .caseInsensitive : [])
        else { return content }
        lines[line].replaceSubrange(range, with: checked ? "[ ]" : "[x]")
        return lines.joined(separator: "\n")
    }

    // MARK: Return

    /// What Return does on a list or quote line: starts the next item, or on an empty item ends
    /// the list. Nil means an ordinary line break, as inside a code block.
    public static func continueList(in text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        guard isValid(selection, in: ns) else { return nil }
        let line = lineContent(at: selection.location, in: ns)
        guard !isInCodeBlock(ns, lineStart: line.location) else { return nil }
        let head = ns.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let prefix = LinePrefix(parsing: head)
        let isHeading = if case .heading = prefix.marker { true } else { false }
        guard !prefix.quote.isEmpty || (prefix.marker != nil && !isHeading) else { return nil }

        let content = (head as NSString).substring(from: prefix.length)
        let tailEnd = NSMaxRange(lineContent(at: NSMaxRange(selection), in: ns))
        let tail = ns.substring(with: NSRange(location: NSMaxRange(selection), length: tailEnd - NSMaxRange(selection)))
        if content.trimmingCharacters(in: .whitespaces).isEmpty && tail.trimmingCharacters(in: .whitespaces).isEmpty {
            // An empty item ends the list. Inside a quote only the marker goes; an empty quote
            // line ends the quote.
            let kept = prefix.marker != nil && !isHeading && !prefix.quote.isEmpty ? prefix.indent + prefix.quote : ""
            return TextEdit(
                range: NSRange(location: line.location, length: NSMaxRange(selection) - line.location),
                replacement: kept,
                selection: NSRange(location: line.location + kept.utf16.count, length: 0)
            )
        }

        let next: String = switch prefix.marker {
        case .bullet(let bullet): "\(bullet) "
        case .task(let bullet): "\(bullet) [ ] "
        case .number(let number, let delimiter): "\(number + 1)\(delimiter) "
        case .heading, nil: ""
        }
        let replacement = "\n" + prefix.indent + prefix.quote + next
        return TextEdit(range: selection, replacement: replacement, selection: NSRange(location: selection.location + replacement.utf16.count, length: 0))
    }

    // MARK: Formatting

    /// Applies or removes `format` at the selection. Inline styles wrap the selection or unwrap
    /// it when it's already wrapped; line styles apply to every selected line, or come off when
    /// every line already has them.
    public static func edit(_ format: MarkdownFormat, in text: String, selection: NSRange) -> TextEdit {
        let selection = clamped(selection, in: text as NSString)
        return switch format {
        case .bold: toggleInline("**", in: text, selection: selection)
        case .italic: toggleInline("*", in: text, selection: selection)
        case .strikethrough: toggleInline("~~", in: text, selection: selection)
        case .code: toggleInline("`", in: text, selection: selection)
        case .heading1: toggleLines(.heading(1), in: text, selection: selection)
        case .heading2: toggleLines(.heading(2), in: text, selection: selection)
        case .heading3: toggleLines(.heading(3), in: text, selection: selection)
        case .bulletList: toggleLines(.bullet, in: text, selection: selection)
        case .numberedList: toggleLines(.number, in: text, selection: selection)
        case .taskList: toggleLines(.task, in: text, selection: selection)
        case .quote: toggleLines(.quote, in: text, selection: selection)
        case .link: link(in: text, selection: selection)
        case .codeBlock: codeBlock(in: text, selection: selection)
        }
    }

    /// Types a `#` to start a tag, after a space when the cursor follows a word. A selected word
    /// becomes the tag.
    public static func insertTagMarker(in text: String, selection: NSRange) -> TextEdit {
        let ns = text as NSString
        let selection = clamped(selection, in: ns)
        var lead = ""
        if selection.location > 0 {
            let previous = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: selection.location - 1))
            if let character = previous.first, !TagScanner.isBoundary(character) || character == "\\" { lead = " " }
        }
        let replacement = lead + "#" + ns.substring(with: selection)
        return TextEdit(range: selection, replacement: replacement, selection: NSRange(location: selection.location + replacement.utf16.count, length: 0))
    }

    // MARK: Tags

    /// The `#tag` the cursor is in, for suggestions. A lone `#` counts, and so does a nested tag
    /// whose `/` was just typed.
    public static func tagToken(in text: String, at cursor: Int) -> TagToken? {
        let ns = text as NSString
        guard cursor > 0, cursor <= ns.length else { return nil }
        let lineRange = lineContent(at: cursor, in: ns)
        guard !isInCodeBlock(ns, lineStart: lineRange.location) else { return nil }
        let line = ns.substring(with: lineRange)
        let lineNS = line as NSString
        let local = cursor - lineRange.location
        guard local > 0 else { return nil }
        let spans = TagScanner.codeSpans(in: line)

        func token(_ range: NSRange) -> TagToken {
            TagToken(
                range: NSRange(location: lineRange.location + range.location, length: range.length),
                prefix: lineNS.substring(with: NSRange(location: range.location + 1, length: local - range.location - 1))
            )
        }

        for match in TagScanner.matches(in: line, excluding: spans) {
            let range = NSRange(match.range, in: line)
            if range.location < local && local <= NSMaxRange(range) { return token(range) }
            if NSMaxRange(range) == local - 1, lineNS.character(at: local - 1) == slash {
                return token(NSRange(location: range.location, length: range.length + 1))
            }
        }

        // A `#` with nothing after it yet.
        guard lineNS.character(at: local - 1) == hash else { return nil }
        if local > 1 {
            let previous = lineNS.substring(with: lineNS.rangeOfComposedCharacterSequence(at: local - 2))
            guard let character = previous.first, TagScanner.isBoundary(character), character != "\\" else { return nil }
        }
        if local < lineNS.length {
            let next = lineNS.substring(with: lineNS.rangeOfComposedCharacterSequence(at: local))
            if let character = next.first, TagScanner.isTagCharacter(character) { return nil }
        }
        if let index = Range(NSRange(location: local - 1, length: 1), in: line)?.lowerBound,
           spans.contains(where: { $0.contains(index) }) {
            return nil
        }
        return token(NSRange(location: local - 1, length: 1))
    }

    /// Replaces the token with `#tag` and a space, leaving the cursor after the space.
    public static func completeTag(_ tag: String, replacing token: TagToken, in text: String) -> TextEdit {
        let ns = text as NSString
        let end = NSMaxRange(token.range)
        let hasSpace = end < ns.length && ns.character(at: end) == space
        let replacement = "#" + tag + (hasSpace ? "" : " ")
        return TextEdit(range: token.range, replacement: replacement, selection: NSRange(location: token.range.location + replacement.utf16.count + (hasSpace ? 1 : 0), length: 0))
    }

    /// Tags to offer for `prefix`, from `tags` in the order given (most used first): those that
    /// start with it, then nested tags with a level that does.
    public static func tagSuggestions(for prefix: String, in tags: [String], limit: Int = 20) -> [String] {
        guard !prefix.isEmpty else { return Array(tags.prefix(limit)) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        var leading: [String] = []
        var nested: [String] = []
        for tag in tags {
            if tag.range(of: prefix, options: options) != nil {
                leading.append(tag)
            } else if tag.split(separator: "/").dropFirst().contains(where: { $0.range(of: prefix, options: options) != nil }) {
                nested.append(tag)
            }
        }
        return Array((leading + nested).prefix(limit))
    }

    // MARK: - Inline

    private static func toggleInline(_ marker: String, in text: String, selection: NSRange) -> TextEdit {
        let ns = text as NSString
        let segments = inlineSegments(of: selection, in: ns)
        guard segments.count > 1 else {
            return toggleInline(marker, in: ns, range: segments.first ?? NSRange(location: selection.location, length: 0))
        }
        // Emphasis can't cross lines, so each selected line is wrapped on its own.
        let wrapped = segments.allSatisfy { innerRun(of: marker, in: ns, range: $0) }
        let length = marker.utf16.count
        var replacement = ""
        var position = segments[0].location
        for segment in segments {
            replacement += ns.substring(with: NSRange(location: position, length: segment.location - position))
            if wrapped {
                replacement += ns.substring(with: NSRange(location: segment.location + length, length: segment.length - 2 * length))
            } else {
                replacement += marker + ns.substring(with: segment) + marker
            }
            position = NSMaxRange(segment)
        }
        let range = NSRange(location: segments[0].location, length: position - segments[0].location)
        return TextEdit(range: range, replacement: replacement, selection: NSRange(location: range.location, length: replacement.utf16.count))
    }

    private static func toggleInline(_ marker: String, in ns: NSString, range: NSRange) -> TextEdit {
        let length = marker.utf16.count
        let unit = marker.utf16.first!
        let selected = ns.substring(with: range)
        // **|bold|** → bold, and an empty pair comes out again.
        let outside = min(run(of: unit, in: ns, from: range.location, step: -1, limit: 0),
                          run(of: unit, in: ns, from: NSMaxRange(range), step: 1, limit: ns.length))
        if marks(outside, marker) {
            return TextEdit(
                range: NSRange(location: range.location - length, length: range.length + 2 * length),
                replacement: selected,
                selection: NSRange(location: range.location - length, length: range.length)
            )
        }
        // |**bold**| → bold.
        if innerRun(of: marker, in: ns, range: range) {
            let inner = ns.substring(with: NSRange(location: range.location + length, length: range.length - 2 * length))
            return TextEdit(range: range, replacement: inner, selection: NSRange(location: range.location, length: inner.utf16.count))
        }
        return TextEdit(range: range, replacement: marker + selected + marker, selection: NSRange(location: range.location + length, length: range.length))
    }

    /// Whether `range` starts and ends with `marker`.
    private static func innerRun(of marker: String, in ns: NSString, range: NSRange) -> Bool {
        let length = marker.utf16.count
        guard range.length >= 2 * length else { return false }
        let unit = marker.utf16.first!
        let leading = run(of: unit, in: ns, from: range.location, step: 1, limit: NSMaxRange(range))
        let trailing = run(of: unit, in: ns, from: NSMaxRange(range), step: -1, limit: range.location)
        return leading + trailing <= range.length && marks(min(leading, trailing), marker)
    }

    /// Whether a run of `count` marker characters holds `marker`: `*` and `**` share a character,
    /// so `***` holds both and `**` isn't italic.
    private static func marks(_ count: Int, _ marker: String) -> Bool {
        if marker.first == "*" { return count == marker.utf16.count || count == 3 }
        return count >= marker.utf16.count
    }

    /// How many `unit`s in a row there are from `position`, going forward (`step` 1, reading the
    /// unit at `position`) or backward (`step` -1, reading the unit before it).
    private static func run(of unit: unichar, in ns: NSString, from position: Int, step: Int, limit: Int) -> Int {
        var count = 0
        var index = step > 0 ? position : position - 1
        while (step > 0 ? index < limit : index >= limit), ns.character(at: index) == unit {
            count += 1
            index += step
        }
        return count
    }

    /// The selection split at line breaks, each part without surrounding whitespace, or the
    /// line's own markers where it starts at the beginning of a line.
    private static func inlineSegments(of selection: NSRange, in ns: NSString) -> [NSRange] {
        guard selection.length > 0 else { return [] }
        var segments: [NSRange] = []
        var location = selection.location
        while location < NSMaxRange(selection) {
            let line = lineContent(at: location, in: ns)
            var start = location
            if start == line.location {
                start += LinePrefix(parsing: ns.substring(with: line)).length
            }
            let end = min(NSMaxRange(line), NSMaxRange(selection))
            if start < end {
                let segment = trimmed(NSRange(location: start, length: end - start), in: ns)
                if segment.length > 0 { segments.append(segment) }
            }
            location = NSMaxRange(line) + 1
        }
        return segments
    }

    // MARK: - Lines

    private enum LineFormat {
        case heading(Int), bullet, number, task, quote

        func isApplied(to prefix: LinePrefix) -> Bool {
            switch (self, prefix.marker) {
            case (.heading(let level), .heading(let existing)?): level == existing
            case (.bullet, .bullet?), (.number, .number?), (.task, .task?): true
            case (.quote, _): !prefix.quote.isEmpty
            default: false
            }
        }

        /// The marker that replaces `prefix`'s, keeping the bullet character and a task's check.
        func marker(replacing prefix: LinePrefix, number: Int) -> String {
            switch (self, prefix.marker) {
            case (.heading(let level), _): String(repeating: "#", count: level) + " "
            case (.bullet, .bullet(let bullet)?), (.bullet, .task(let bullet)?): "\(bullet) "
            case (.bullet, _): "- "
            case (.task, .task?): prefix.markerText
            case (.task, .bullet(let bullet)?): "\(bullet) [ ] "
            case (.task, _): "- [ ] "
            case (.number, _): "\(number). "
            case (.quote, _): ""
            }
        }
    }

    private struct Change {
        var location: Int
        var removed: Int
        var inserted: Int
    }

    private static func toggleLines(_ format: LineFormat, in text: String, selection: NSRange) -> TextEdit {
        let ns = text as NSString
        let block = lineBlock(of: selection, in: ns)
        let lines = ns.substring(with: block).components(separatedBy: "\n")
        let prefixes = lines.map(LinePrefix.init(parsing:))
        // Blank lines between selected paragraphs are left alone.
        let targets = lines.map { lines.count == 1 || !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let applied = targets.contains(true) && zip(prefixes, targets).allSatisfy { !$1 || format.isApplied(to: $0) }

        var output: [String] = []
        var changes: [Change] = []
        var lineStart = block.location
        var number = 1
        for (index, line) in lines.enumerated() {
            defer { lineStart += line.utf16.count + 1 }
            guard targets[index] else {
                output.append(line)
                continue
            }
            let prefix = prefixes[index]
            let start: Int
            let removed: String
            let inserted: String
            if case .quote = format {
                start = prefix.indent.utf16.count
                removed = prefix.quote
                inserted = applied ? "" : prefix.quote.isEmpty ? "> " : prefix.quote
            } else {
                start = (prefix.indent + prefix.quote).utf16.count
                removed = prefix.markerText
                inserted = applied ? "" : format.marker(replacing: prefix, number: number)
                number += 1
            }
            output.append((line as NSString).replacingCharacters(in: NSRange(location: start, length: removed.utf16.count), with: inserted))
            changes.append(Change(location: lineStart + start, removed: removed.utf16.count, inserted: inserted.utf16.count))
        }

        let start = map(selection.location, through: changes)
        let end = map(NSMaxRange(selection), through: changes)
        return TextEdit(range: block, replacement: output.joined(separator: "\n"), selection: NSRange(location: start, length: max(0, end - start)))
    }

    /// Where `position` lands after `changes`. A position inside a replaced prefix moves to the
    /// end of the new one.
    private static func map(_ position: Int, through changes: [Change]) -> Int {
        var shift = 0
        for change in changes {
            if position < change.location { break }
            if position <= change.location + change.removed { return change.location + shift + change.inserted }
            shift += change.inserted - change.removed
        }
        return position + shift
    }

    // MARK: - Links and code blocks

    private static func link(in text: String, selection: NSRange) -> TextEdit {
        let ns = text as NSString
        let range = trimmed(selection, in: ns)
        let selected = ns.substring(with: range)
        if let match = selected.wholeMatch(of: /\[([^\]\n]*)\]\([^)\s]*\)/) {
            let label = String(match.1)
            return TextEdit(range: range, replacement: label, selection: NSRange(location: range.location, length: label.utf16.count))
        }
        if selected.isEmpty || selected.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*:\/\/\S+/) != nil {
            // The cursor goes where the words go.
            return TextEdit(range: range, replacement: "[](\(selected))", selection: NSRange(location: range.location + 1, length: 0))
        }
        let replacement = "[\(selected)]()"
        return TextEdit(range: range, replacement: replacement, selection: NSRange(location: range.location + replacement.utf16.count - 1, length: 0))
    }

    private static func codeBlock(in text: String, selection: NSRange) -> TextEdit {
        let ns = text as NSString
        let block = lineBlock(of: selection, in: ns)
        let body = ns.substring(with: block)
        let lines = body.components(separatedBy: "\n")
        if lines.count >= 2, let fence = BlockParser.fence(lines[0].trimmingCharacters(in: .whitespaces)),
           lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == fence.marker {
            let inner = lines.dropFirst().dropLast().joined(separator: "\n")
            return TextEdit(range: block, replacement: inner, selection: NSRange(location: block.location, length: inner.utf16.count))
        }
        let replacement = "```\n" + body + "\n```"
        let opening = 4
        let newSelection = selection.length == 0
            ? NSRange(location: selection.location + opening, length: 0)
            : NSRange(location: block.location + opening, length: body.utf16.count)
        return TextEdit(range: block, replacement: replacement, selection: newSelection)
    }

    // MARK: - Ranges

    private static let newline = unichar(10)
    private static let space = unichar(32)
    private static let hash = unichar(35)
    private static let slash = unichar(47)

    static func isValid(_ range: NSRange, in ns: NSString) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= ns.length
    }

    static func clamped(_ range: NSRange, in ns: NSString) -> NSRange {
        let location = min(max(0, range.location == NSNotFound ? ns.length : range.location), ns.length)
        return NSRange(location: location, length: min(max(0, range.length), ns.length - location))
    }

    /// The line holding `location`, without its line break.
    static func lineContent(at location: Int, in ns: NSString) -> NSRange {
        var line = ns.lineRange(for: NSRange(location: location, length: 0))
        if line.length > 0, ns.character(at: NSMaxRange(line) - 1) == newline { line.length -= 1 }
        return line
    }

    /// Every line the selection touches, without the last line break. A selection that ends just
    /// after a line break doesn't reach into the next line.
    static func lineBlock(of selection: NSRange, in ns: NSString) -> NSRange {
        var end = NSMaxRange(selection)
        if selection.length > 0, ns.character(at: end - 1) == newline { end -= 1 }
        let first = lineContent(at: selection.location, in: ns)
        let last = lineContent(at: max(end, selection.location), in: ns)
        return NSRange(location: first.location, length: max(NSMaxRange(last), NSMaxRange(first)) - first.location)
    }

    static func trimmed(_ range: NSRange, in ns: NSString) -> NSRange {
        let whitespace = CharacterSet.whitespacesAndNewlines
        func isSpace(_ index: Int) -> Bool { Unicode.Scalar(ns.character(at: index)).map(whitespace.contains) ?? false }
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isSpace(start) { start += 1 }
        while end > start, isSpace(end - 1) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Whether the line starting at `lineStart` is inside a fenced code block, going by the
    /// fences above it the way the renderer reads them.
    static func isInCodeBlock(_ ns: NSString, lineStart: Int) -> Bool {
        var open: String?
        for line in ns.substring(to: lineStart).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = open {
                if trimmed.hasPrefix(marker) { open = nil }
            } else if let fence = BlockParser.fence(trimmed) {
                open = fence.marker
            }
        }
        return open != nil
    }
}

/// The Markdown that opens a line: indentation, quote markers, then a heading or list marker.
struct LinePrefix: Equatable {
    enum Marker: Equatable {
        case heading(Int)
        case bullet(Character)
        case task(Character)
        case number(Int, Character)
    }

    var indent: String
    var quote: String
    var marker: Marker?
    /// The marker as written, such as `- [x] `.
    var markerText: String

    var length: Int { (indent + quote + markerText).utf16.count }

    init(parsing line: String) {
        var rest = Substring(line)
        indent = String(rest.prefix { $0 == " " || $0 == "\t" })
        rest = rest.dropFirst(indent.count)
        var quote = ""
        while rest.first == ">" {
            quote += ">"
            rest = rest.dropFirst()
            if rest.first == " " {
                quote += " "
                rest = rest.dropFirst()
            }
        }
        self.quote = quote
        (marker, markerText) = Self.marker(in: rest)
    }

    private static func marker(in text: Substring) -> (Marker?, String) {
        let hashes = text.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), text.dropFirst(hashes).first == " " {
            return (.heading(hashes), String(text.prefix(hashes + 1)))
        }
        if let bullet = text.first, "-*+".contains(bullet), text.dropFirst().first == " " {
            let after = text.dropFirst(2)
            if ["[ ] ", "[x] ", "[X] "].contains(where: after.hasPrefix) {
                return (.task(bullet), String(text.prefix(6)))
            }
            if ["[ ]", "[x]", "[X]"].contains(String(after)) {
                return (.task(bullet), String(text))
            }
            return (.bullet(bullet), String(text.prefix(2)))
        }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        if (1...9).contains(digits.count), let number = Int(digits),
           let delimiter = text.dropFirst(digits.count).first, delimiter == "." || delimiter == ")",
           text.dropFirst(digits.count + 1).first == " " {
            return (.number(number, delimiter), String(text.prefix(digits.count + 2)))
        }
        return (nil, "")
    }
}
