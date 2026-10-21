import Foundation
import Testing
@testable import MemosAPI
@testable import MemosCore

@Suite struct `Activity grid` {
    /// Sunday-first, in UTC, so the dates below mean the same everywhere the tests run.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }()

    static func day(_ text: String, hour: Int = 9) -> Date {
        let parts = text.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
    }

    static func memo(_ day: String, hour: Int = 9, archived: Bool = false) -> Memo {
        var memo = Memo()
        memo.name = "memos/\(day)-\(hour)"
        memo.createTime = .init(Self.day(day, hour: hour))
        memo.state = archived ? .archived : .normal
        return memo
    }

    @Test func `counts memos per day, leaving out archived ones`() {
        let activity = MemoActivity(memos: [
            Self.memo("2026-10-19", hour: 1), Self.memo("2026-10-19", hour: 23), Self.memo("2026-10-19", archived: true),
            Self.memo("2026-10-20"),
        ], calendar: Self.calendar)
        #expect(activity.count(on: Self.day("2026-10-19")) == 2)
        #expect(activity.count(on: Self.day("2026-10-20")) == 1)
        #expect(activity.count(on: Self.day("2026-10-18")) == 0)
        #expect(activity.memoCount == 3)
        #expect(activity.memoCount(inMonthOf: Self.day("2026-10-01")) == 3)
        #expect(activity.memoCount(inMonthOf: Self.day("2026-11-01")) == 0)
    }

    @Test func `levels follow the share of active days with fewer memos`() {
        // Six days: three with 1 memo, then 2, 3 and 20.
        var counts: [Date: Int] = [:]
        for (offset, count) in [1, 1, 1, 2, 3, 20].enumerated() {
            counts[Self.calendar.date(byAdding: .day, value: offset, to: Self.day("2026-10-01", hour: 0))!] = count
        }
        let activity = MemoActivity(counts: counts, calendar: Self.calendar)
        #expect(activity.level(on: Self.day("2026-09-30")) == 0)
        #expect(activity.level(on: Self.day("2026-10-01")) == 1)
        #expect(activity.level(on: Self.day("2026-10-04")) == 3)
        // The busiest day only lifts itself: a 3-memo day still reaches level 3, not level 1.
        #expect(activity.level(on: Self.day("2026-10-05")) == 3)
        #expect(activity.level(on: Self.day("2026-10-06")) == 4)
    }

    @Test func `writing the same amount every day stays on the first level`() {
        let activity = MemoActivity(memos: ["2026-10-17", "2026-10-18", "2026-10-19"].map { Self.memo($0) }, calendar: Self.calendar)
        #expect(activity.level(on: Self.day("2026-10-18")) == 1)
    }

    @Test func `a streak survives a today without memos yet`() {
        let activity = MemoActivity(memos: ["2026-10-15", "2026-10-17", "2026-10-18", "2026-10-19"].map { Self.memo($0) }, calendar: Self.calendar)
        #expect(activity.streak(through: Self.day("2026-10-19")) == 3)
        #expect(activity.streak(through: Self.day("2026-10-20")) == 3)
        #expect(activity.streak(through: Self.day("2026-10-21")) == 0)
        #expect(MemoActivity(memos: [], calendar: Self.calendar).streak(through: Self.day("2026-10-20")) == 0)
    }

    @Test(arguments: [(1, "2026-10-04"), (2, "2026-10-05")])
    func `columns are whole weeks ending with this one`(firstWeekday: Int, firstDay: String) {
        var calendar = Self.calendar
        calendar.firstWeekday = firstWeekday
        // Tuesday, 20 October 2026.
        let columns = MemoActivity(memos: [], calendar: calendar).weeks(3, through: Self.day("2026-10-20"))
        #expect(columns.count == 3)
        #expect(columns.allSatisfy { $0.count == 7 })
        #expect(columns[0][0] == Self.day(firstDay, hour: 0))
        #expect(columns[2].contains(Self.day("2026-10-20", hour: 0)))
        #expect(calendar.component(.weekday, from: columns[1][0]) == firstWeekday)
    }

    @Test func `on the first day of the week, today starts the last column`() {
        let columns = MemoActivity(memos: [], calendar: Self.calendar).weeks(2, through: Self.day("2026-10-18"))
        #expect(columns[1][0] == Self.day("2026-10-18", hour: 0))
    }
}
