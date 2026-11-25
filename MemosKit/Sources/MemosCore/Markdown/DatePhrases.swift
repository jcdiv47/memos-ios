import Foundation

/// A date written the way people say it, like “tomorrow 8pm” or “next Wednesday”, just before
/// the cursor.
public struct DatePhrase: Equatable, Sendable {
    /// The phrase as typed.
    public var range: NSRange
    public var date: Date
    /// False for a day with no time, like “next Wednesday”.
    public var includesTime: Bool

    public init(range: NSRange, date: Date, includesTime: Bool) {
        self.range = range
        self.date = date
        self.includesTime = includesTime
    }
}

/// Finds natural-language dates as they're typed and writes them out in full, in the device's
/// time zone, so a memo read next month still says which Wednesday it meant.
public enum DatePhrases {
    /// The system's detector reads relative dates against now, in the device's time zone. It's
    /// immutable once made, so sharing it across threads is safe.
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// The date phrase that ends at `cursor`, or with only spaces between it and the cursor.
    /// Phrases inside code, and ones that already name a year, are left alone: they're either not
    /// prose or already say exactly when.
    public static func phrase(in text: String, before cursor: Int) -> DatePhrase? {
        let ns = text as NSString
        guard cursor > 0, cursor <= ns.length, let detector else { return nil }
        let lineRange = MarkdownEditing.lineContent(at: cursor, in: ns)
        guard !MarkdownEditing.isInFencedBlock(ns, lineStart: lineRange.location) else { return nil }
        let local = cursor - lineRange.location
        guard local > 0 else { return nil }
        let line = ns.substring(with: NSRange(location: lineRange.location, length: local))
        let lineNS = line as NSString

        // Only spaces may sit between the phrase and the cursor.
        var end = local
        while end > 0, lineNS.character(at: end - 1) == space || lineNS.character(at: end - 1) == tab { end -= 1 }
        guard end > 0 else { return nil }
        // In the middle of a word, like “at 8|pm”, the phrase isn't finished.
        if end == local, cursor < NSMaxRange(lineRange),
           let next = Unicode.Scalar(ns.character(at: cursor)), CharacterSet.alphanumerics.contains(next) { return nil }

        // A span like “until tomorrow” has a duration; it isn't one moment to write down.
        guard let match = detector.matches(in: line, range: NSRange(location: 0, length: lineNS.length))
            .last(where: { NSMaxRange($0.range) == end }),
            let date = match.date, match.duration == 0
        else { return nil }

        let typed = lineNS.substring(with: match.range)
        guard !namesYear(typed) else { return nil }
        // An odd number of backticks before it puts the phrase inside `code`, closed or not.
        let backticks = lineNS.substring(to: match.range.location).count { $0 == "`" }
        guard backticks.isMultiple(of: 2) else { return nil }

        // The detector reads “dinner” as 7pm and takes the word with it; the memo keeps it.
        let core = withoutMeals(typed)
        guard core.length > 0 else { return nil }

        return DatePhrase(
            range: NSRange(location: lineRange.location + match.range.location + core.location, length: core.length),
            date: date,
            includesTime: includesTime(date, typed: typed)
        )
    }

    /// The date in full, like “Fri, Nov 20, 2026 at 8:00 PM”.
    public static func formatted(
        _ date: Date, includesTime: Bool,
        timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
            .weekday(.abbreviated).month(.abbreviated).day().year()
        return includesTime ? date.formatted(style.hour().minute()) : date.formatted(style)
    }

    /// Replaces `phrase` with the date in full. The cursor keeps its place after it.
    public static func convert(
        _ phrase: DatePhrase, cursor: Int,
        timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent
    ) -> TextEdit {
        let replacement = formatted(phrase.date, includesTime: phrase.includesTime, timeZone: timeZone, locale: locale)
        let delta = replacement.utf16.count - phrase.range.length
        return TextEdit(range: phrase.range, replacement: replacement, selection: NSRange(location: cursor + delta, length: 0))
    }

    // MARK: - Private

    private static let space = unichar(32)
    private static let tab = unichar(9)

    private static let meal = "(?:breakfast|brunch|lunchtime|lunch|dinnertime|dinner|supper|早饭|早餐|午饭|午餐|晚饭|晚餐|夜宵)"
    /// “Dinner ” or “brunch on ” before the date. Not “dinner at ”, whose “at” the time takes.
    private static let leadingMeal = try? NSRegularExpression(pattern: "^\(meal)(?:\\s+on)?\\s*", options: .caseInsensitive)
    /// “ lunch”, “ for dinner” or “ at lunch” after it.
    private static let trailingMeal = try? NSRegularExpression(pattern: "\\s*(?:(?:for|at)\\s+)?\(meal)$", options: .caseInsensitive)

    /// The part of `typed` that says when, without the meals around it.
    private static func withoutMeals(_ typed: String) -> NSRange {
        let ns = typed as NSString
        var range = NSRange(location: 0, length: ns.length)
        if let leading = leadingMeal?.firstMatch(in: typed, range: range) {
            range = NSRange(location: leading.range.length, length: range.length - leading.range.length)
        }
        if let trailing = trailingMeal?.firstMatch(in: typed, range: range) {
            range.length = trailing.range.location - range.location
        }
        return range
    }

    /// Four digits in a row: a year, so the date is already exact. This is also what keeps a
    /// date that was just written out from being offered again.
    private static func namesYear(_ typed: String) -> Bool {
        var run = 0
        for character in typed {
            run = character.isASCII && character.isNumber ? run + 1 : 0
            if run == 4 { return true }
        }
        return false
    }

    /// The detector puts a day with no time at noon. Noon only counts as a time when the phrase
    /// says so.
    private static func includesTime(_ date: Date, typed: String) -> Bool {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute, .second], from: date)
        guard parts.hour == 12, parts.minute == 0, parts.second == 0 else { return true }
        let lowered = typed.lowercased()
        return ["12", "noon", "midday", "中午", "正午", "十二"].contains { lowered.contains($0) }
    }
}
