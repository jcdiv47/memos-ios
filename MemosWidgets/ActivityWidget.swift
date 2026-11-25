import MemosCore
import SwiftUI
import WidgetKit

struct ActivityEntry: TimelineEntry {
    /// Also the day the grid ends on.
    var date: Date
    /// Nil when signed out.
    var activity: MemoActivity?
}

struct ActivityProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActivityEntry {
        ActivityEntry(date: .now, activity: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (ActivityEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(ActivityEntry(date: .now, activity: await Self.activity())) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ActivityEntry>) -> Void) {
        Task {
            let activity = await Self.activity()
            // A second entry at midnight moves the grid on a day even if the reload runs late.
            let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400))
            let entries = [ActivityEntry(date: .now, activity: activity), ActivityEntry(date: midnight, activity: activity)]
            completion(Timeline(entries: entries, policy: .atEnd))
        }
    }

    static func activity() async -> MemoActivity? {
        guard let location = AccountLocation.current else { return nil }
        return MemoActivity(memos: await AccountArchive.readOwnMemos(location))
    }

    static let sample: MemoActivity = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var counts: [Date: Int] = [:]
        for offset in 0..<200 where offset % 4 != 3 {
            if let day = calendar.date(byAdding: .day, value: -offset, to: today) {
                counts[day] = offset * 7 % 5 + 1
            }
        }
        return MemoActivity(counts: counts, calendar: calendar)
    }()
}

/// The Library's activity grid: as many recent weeks as fit.
struct ActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Activity", provider: ActivityProvider()) { entry in
            ActivityWidgetView(entry: entry)
                .containerBackground(.paper, for: .widget)
        }
        .configurationDisplayName("Activity")
        .description("How often you’ve written lately, day by day.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ActivityWidgetView: View {
    let entry: ActivityEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.m) {
                WidgetHeader(title: "Activity", icon: .calendar)
                    .labelStyle(.titleOnly)
                Spacer(minLength: 0)
                if let activity = entry.activity {
                    summary(activity)
                }
            }
            if let activity = entry.activity {
                ActivityGrid(activity: activity, today: entry.date)
            } else {
                WidgetNote("Open Memos and sign in.")
                Spacer(minLength: 0)
            }
        }
        .widgetURL(URL(string: "memos://library/activity"))
    }

    @ViewBuilder
    private func summary(_ activity: MemoActivity) -> some View {
        let streak = activity.streak(through: entry.date)
        Group {
            if activity.memoCount == 0 {
                Text("No memos yet")
            } else {
                if family != .systemSmall {
                    Text("\(activity.memoCount) memos")
                        .monospacedDigit()
                }
                if streak > 0 {
                    Label {
                        Text(streak, format: .number)
                    } icon: {
                        Image(icon: .flameFill)
                    }
                        .monospacedDigit()
                        .foregroundStyle(.memosBlue)
                        .widgetAccentable()
                        .accessibilityLabel("\(streak)-day streak")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.ink2)
        .lineLimit(1)
    }
}

/// Squares sized to fill the height, with as many weeks as then fit across, newest on the right.
struct ActivityGrid: View {
    let activity: MemoActivity
    let today: Date

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3  // The app's activity grid gap.
            let cell = min((proxy.size.height - spacing * 6) / 7, 16)
            let weeks = max(Int((proxy.size.width + spacing) / (cell + spacing)), 1)
            HStack(alignment: .top, spacing: spacing) {
                ForEach(activity.weeks(weeks, through: today), id: \.self) { week in
                    VStack(spacing: spacing) {
                        ForEach(week, id: \.self) { day in
                            RoundedRectangle(cornerRadius: cell * 0.22)
                                .fill(fill(for: day))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .accessibilityHidden(true)
    }

    /// The Library's scale. Tinted and clear Home Screens keep only each colour's opacity, so
    /// there the levels become opacity steps and empty squares stay faint.
    private func fill(for day: Date) -> Color {
        if day > today { return .clear }
        let level = activity.level(on: day)
        if renderingMode == .fullColor { return .activity(level: level) }
        return .primary.opacity([0.15, 0.3, 0.5, 0.75, 1][level])
    }
}
