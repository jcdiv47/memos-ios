import Foundation

/// How many of your memos fall on each day: the activity grid in Library and its widget.
public struct MemoActivity: Sendable, Equatable {
    /// Memo counts keyed by the start of each day.
    public let counts: [Date: Int]
    /// The busiest day's count, which the darkest square stands for. At least 1.
    public let maxCount: Int
    /// Every memo counted, across all days.
    public let memoCount: Int
    let calendar: Calendar

    /// Counts memos that aren't archived, by the day they were created.
    public init(memos: some Sequence<Memo>, calendar: Calendar = .current) {
        var counts: [Date: Int] = [:]
        for memo in memos where !memo.isArchived {
            counts[calendar.startOfDay(for: memo.createdAt), default: 0] += 1
        }
        self.init(counts: counts, calendar: calendar)
    }

    public init(counts: [Date: Int], calendar: Calendar = .current) {
        self.counts = counts
        self.calendar = calendar
        maxCount = max(counts.values.max() ?? 1, 1)
        memoCount = counts.values.reduce(0, +)
    }

    public func count(on day: Date) -> Int {
        counts[calendar.startOfDay(for: day)] ?? 0
    }

    /// How strongly to tint a day's square: 0 for an empty day, otherwise from a quarter for one
    /// memo up to full for the busiest day, so a single memo still reads at a glance.
    public func intensity(on day: Date) -> Double {
        let count = count(on: day)
        return count == 0 ? 0 : 0.25 + 0.75 * Double(count) / Double(maxCount)
    }

    /// Days in a row with at least one memo, up to today. Today doesn't break the streak until
    /// it's over, so a morning without a memo yet still shows yesterday's run.
    public func streak(through today: Date) -> Int {
        var day = calendar.startOfDay(for: today)
        if count(on: day) == 0, let yesterday = calendar.date(byAdding: .day, value: -1, to: day) {
            day = yesterday
        }
        var streak = 0
        while count(on: day) > 0, let previous = calendar.date(byAdding: .day, value: -1, to: day) {
            streak += 1
            day = previous
        }
        return streak
    }

    /// The grid's columns, oldest first: `weeks` calendar weeks of seven days each, starting on
    /// the calendar's first weekday and ending with the week containing `today`. Days after
    /// today are included, for the caller to leave blank.
    public func weeks(_ weeks: Int, through today: Date) -> [[Date]] {
        let today = calendar.startOfDay(for: today)
        let intoWeek = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        guard weeks > 0, let start = calendar.date(byAdding: .day, value: -intoWeek - (weeks - 1) * 7, to: today) else { return [] }
        return (0..<weeks).map { week in
            (0..<7).compactMap { calendar.date(byAdding: .day, value: week * 7 + $0, to: start) }
        }
    }
}
