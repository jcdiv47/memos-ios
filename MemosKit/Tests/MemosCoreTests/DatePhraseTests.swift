import Foundation
import Testing
@testable import MemosCore

/// `marked` with the cursor shown by `|`.
private func unmark(_ marked: String) -> (text: String, cursor: Int) {
    let parts = marked.components(separatedBy: "|")
    precondition(parts.count == 2, "mark the cursor")
    return (parts.joined(), parts[0].utf16.count)
}

private func phrase(_ marked: String) -> (typed: String, phrase: DatePhrase)? {
    let (text, cursor) = unmark(marked)
    guard let phrase = DatePhrases.phrase(in: text, before: cursor) else { return nil }
    return ((text as NSString).substring(with: phrase.range), phrase)
}

/// Midnight today, plus `days`, at `hour`:`minute`, in the device's time zone.
private func day(_ days: Int, hour: Int = 12, minute: Int = 0) -> Date {
    let calendar = Calendar.autoupdatingCurrent
    let start = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: .now))!
    return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start)!
}

@Suite struct `Date phrases` {
    @Test func `tomorrow at a time`() throws {
        let found = try #require(phrase("Call mom tomorrow 8pm|"))
        #expect(found.typed == "tomorrow 8pm")
        #expect(found.phrase.date == day(1, hour: 20))
        #expect(found.phrase.includesTime)
    }

    @Test func `a weekday is a day without a time`() throws {
        let found = try #require(phrase("See you next Wednesday|"))
        #expect(found.typed == "next Wednesday")
        #expect(!found.phrase.includesTime)
        #expect(Calendar.autoupdatingCurrent.component(.weekday, from: found.phrase.date) == 4)
        #expect(found.phrase.date > .now)
    }

    @Test func `noon said out loud is a time`() throws {
        #expect(try #require(phrase("Lunch tomorrow at noon|")).phrase.includesTime)
        #expect(try #require(phrase("Lunch tomorrow at 12pm|")).phrase.includesTime)
        #expect(try #require(phrase("today|")).phrase.includesTime == false)
    }

    @Test(arguments: [
        ("Dinner next Wednesday|", "next Wednesday"),
        ("dinner at 7 tomorrow|", "at 7 tomorrow"),
        ("brunch on Sunday|", "Sunday"),
        ("tomorrow for dinner|", "tomorrow"),
        ("Friday at lunch|", "Friday"),
    ])
    func `meals stay in the memo`(marked: String, typed: String) throws {
        #expect(try #require(phrase(marked)).typed == typed)
    }

    // NSDataDetector on headless CI simulators (e.g. Xcode Cloud) may not have Chinese
    // DataDetector language assets installed even when zh is in preferred languages.
    private static var supportsChineseDates: Bool {
        let sample = "明天晚上8点"
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        return detector?.firstMatch(in: sample, range: NSRange(location: 0, length: (sample as NSString).length)) != nil
    }

    @Test(.enabled(if: supportsChineseDates))
    func `Chinese`() throws {
        let found = try #require(phrase("明天晚上8点|"))
        #expect(found.phrase.date == day(1, hour: 20))
    }

    @Test func `spaces after the phrase still count`() throws {
        #expect(try #require(phrase("Call mom tomorrow 8pm  |")).typed == "tomorrow 8pm")
    }

    @Test(arguments: [
        "Call mom tomorrow 8pm about it|",
        "Call mom tomorrow 8pm\n|",
        "Call mom|",
        "Off until tomorrow|",
        "晚饭|",
        "|",
        "Dentist Wed, Nov 25, 2026|",
        "2026-11-20 20:00|",
        "`tomorrow 8pm|",
        "tomorrow|land",
        "`tomorrow 8pm`|",
        "```\ntomorrow 8pm|",
        "$$\ntomorrow 8pm|",
    ])
    func `nothing to offer`(marked: String) {
        #expect(phrase(marked) == nil)
    }

    @Test func `only the cursor's line is read`() throws {
        #expect(try #require(phrase("tomorrow\nnext Wednesday|")).typed == "next Wednesday")
    }

    @Test func `written out in full`() {
        let zone = TimeZone(identifier: "America/New_York")!
        let locale = Locale(identifier: "en_US")
        // Times put a narrow no-break space before “PM”.
        func formatted(_ includesTime: Bool, _ zone: TimeZone) -> String {
            DatePhrases.formatted(date, includesTime: includesTime, timeZone: zone, locale: locale)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 20))!
        #expect(formatted(true, zone) == "Fri, Nov 20, 2026 at 8:00 PM")
        #expect(formatted(false, zone) == "Fri, Nov 20, 2026")
        // The same moment, read on a phone in another time zone.
        #expect(formatted(true, TimeZone(identifier: "Asia/Shanghai")!) == "Sat, Nov 21, 2026 at 9:00 AM")
    }

    @Test func `converting keeps the cursor after the phrase`() throws {
        let (text, cursor) = unmark("Call mom tomorrow 8pm |")
        let found = try #require(DatePhrases.phrase(in: text, before: cursor))
        let edit = DatePhrases.convert(found, cursor: cursor, locale: Locale(identifier: "en_US"))
        let result = edit.applied(to: text)
        let written = DatePhrases.formatted(day(1, hour: 20), includesTime: true, locale: Locale(identifier: "en_US"))
        #expect(result == "Call mom \(written) ")
        #expect(edit.selection == NSRange(location: (result as NSString).length, length: 0))
        // What was just written isn't offered again.
        #expect(DatePhrases.phrase(in: result, before: edit.selection.location) == nil)
    }
}
