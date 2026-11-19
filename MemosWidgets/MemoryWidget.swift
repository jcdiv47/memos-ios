import AppIntents
import MemosCore
import SwiftUI
import WidgetKit

enum MemoryFrequency: String, AppEnum {
    case hourly, everyFourHours, daily

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Frequency"
    static let caseDisplayRepresentations: [MemoryFrequency: DisplayRepresentation] = [
        .hourly: "Every Hour",
        .everyFourHours: "Every 4 Hours",
        .daily: "Every Day",
    ]

    var hours: Int {
        switch self {
        case .hourly: 1
        case .everyFourHours: 4
        case .daily: 24
        }
    }
}

struct MemoryWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Memory"
    static let description = IntentDescription("Shows one of your memos at random.")

    // Its own key: “New Memo” elsewhere is a command, here it labels how often the memo changes.
    @Parameter(title: LocalizedStringResource("New Memo (frequency)", defaultValue: "New Memo", comment: "Memory widget setting: how often the widget shows a different memo, as in “New Memo: Every Day”."), default: .daily)
    var frequency: MemoryFrequency

    @Parameter(title: "Tag")
    var tag: WidgetTagEntity?
}

struct MemoryEntry: TimelineEntry {
    enum Content {
        case memo(Memo)
        /// Nothing to show, or nothing with the chosen tag.
        case empty(tag: String?)
        case signedOut
    }

    var date: Date
    var content: Content
}

/// Lays out a day of memories ahead, so the widget keeps changing without the app running.
struct MemoryProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MemoryEntry {
        MemoryEntry(date: .now, content: .memo(MemosProvider.samples[0]))
    }

    func snapshot(for configuration: MemoryWidgetIntent, in context: Context) async -> MemoryEntry {
        if context.isPreview { return placeholder(in: context) }
        return await timeline(for: configuration, in: context).entries.first ?? placeholder(in: context)
    }

    func timeline(for configuration: MemoryWidgetIntent, in context: Context) async -> Timeline<MemoryEntry> {
        guard let contents = await WidgetStore.load() else {
            return Timeline(entries: [MemoryEntry(date: .now, content: .signedOut)], policy: .never)
        }
        let calendar = Calendar.current
        let hours = configuration.frequency.hours
        let tag = configuration.tag?.id
        // A memory you can't read isn't much of one, so memos with a blurred tag stay out.
        let pool = contents.memos
            .filter { memo in
                !memo.isComment && !contents.rules.blurs(memo)
                    && !memo.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (tag.map { TagScanner.hierarchy(memo.tags).contains($0) } ?? true)
            }
            .sorted { $0.name < $1.name }
        let slots = MemoryRotation.slots(every: hours, from: .now, calendar: calendar)
        guard !pool.isEmpty else {
            return Timeline(entries: [MemoryEntry(date: .now, content: .empty(tag: tag))], policy: .after(slots.end))
        }
        let entries = slots.starts.map { start in
            MemoryEntry(date: start, content: .memo(MemoryRotation.memo(from: pool, at: start, every: hours, calendar: calendar)))
        }
        return Timeline(entries: entries, policy: .after(slots.end))
    }
}

/// Which memo each slot of the day shows. The choice depends only on the slot and the memos, so
/// the reload the app asks for whenever it leaves the foreground keeps the memo that's showing.
enum MemoryRotation {
    /// The next day's slots, on the clock: every hour, every four hours from midnight, or daily
    /// at midnight. The first is the slot already under way.
    static func slots(every hours: Int, from now: Date, calendar: Calendar) -> (starts: [Date], end: Date) {
        let today = calendar.startOfDay(for: now)
        let current = calendar.component(.hour, from: now) / hours
        let dates = (current...(current + 24 / hours)).compactMap { slot -> Date? in
            let day = calendar.date(byAdding: .day, value: slot * hours / 24, to: today)
            return day.flatMap { calendar.date(bySettingHour: slot * hours % 24, minute: 0, second: 0, of: $0) }
        }
        return (Array(dates.dropLast()), dates.last ?? today.addingTimeInterval(86_400))
    }

    /// Each day gets its own shuffle of the memos and walks through it, so a day doesn't repeat
    /// a memo until it runs out.
    static func memo(from pool: [Memo], at slot: Date, every hours: Int, calendar: Calendar) -> Memo {
        let day = calendar.startOfDay(for: slot)
        var generator = SeededGenerator(seed: UInt64(bitPattern: Int64(day.timeIntervalSince1970)))
        let order = pool.indices.shuffled(using: &generator)
        return pool[order[calendar.component(.hour, from: slot) / hours % order.count]]
    }
}

/// SplitMix64: the same seed gives the same sequence on every run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A random memo of yours, changing on a schedule you choose.
struct MemoryWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Memory", intent: MemoryWidgetIntent.self, provider: MemoryProvider()) { entry in
            MemoryWidgetView(entry: entry)
                .containerBackground(.paper, for: .widget)
        }
        .configurationDisplayName("Memory")
        .description("A memo from your past, changing every hour, every 4 hours or every day.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct MemoryWidgetView: View {
    let entry: MemoryEntry

    var body: some View {
        switch entry.content {
        case .memo(let memo):
            // Memos with a blurred tag never get here.
            MemoWidgetView(memo: memo, sensitive: false) {
                Label {
                    Text(memo.createdAt, format: .relative(presentation: .named))
                } icon: {
                    Image(systemName: "sparkles")
                }
            }
        case .empty(let tag?):
            message("No memos tagged #\(tag) to show.")
        case .empty(nil):
            message("Your memos show up here, one at a time.")
        case .signedOut:
            message("Open Memos and sign in.")
        }
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            WidgetHeader(title: "Memory", systemImage: "sparkles")
            WidgetNote(text)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
