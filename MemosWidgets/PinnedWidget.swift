import AppIntents
import MemosCore
import SwiftUI
import WidgetKit

/// The Pinned widget's one setting. Left empty, the widget lists your pinned memos as it did
/// before it had settings, which is also what widgets already on the Home Screen get.
struct PinnedWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Pinned"
    static let description = IntentDescription("Choose a memo to keep in view, or leave it empty to show your pinned memos.")

    @Parameter(title: "Memo")
    var memo: WidgetMemoEntity?
}

struct PinnedEntry: TimelineEntry {
    enum Content {
        /// Nothing chosen: your pinned memos.
        case pinned(MemosEntry)
        case memo(Memo, sensitive: Bool)
        /// The chosen memo was deleted or archived.
        case unavailable
    }

    var date: Date
    var content: Content
}

struct PinnedProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PinnedEntry {
        PinnedEntry(date: .now, content: .pinned(MemosEntry(date: .now, memos: MemosProvider.samples, signedIn: true)))
    }

    func snapshot(for configuration: PinnedWidgetIntent, in context: Context) async -> PinnedEntry {
        context.isPreview ? placeholder(in: context) : await Self.entry(for: configuration)
    }

    func timeline(for configuration: PinnedWidgetIntent, in context: Context) async -> Timeline<PinnedEntry> {
        // The app reloads widgets when memos change; midnight is a backstop.
        let next = Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400))
        return Timeline(entries: [await Self.entry(for: configuration)], policy: .after(next))
    }

    static func entry(for configuration: PinnedWidgetIntent) async -> PinnedEntry {
        guard let id = configuration.memo?.id else {
            return PinnedEntry(date: .now, content: .pinned(await MemosProvider.entry(kind: .pinned)))
        }
        guard let contents = await WidgetStore.load() else {
            return PinnedEntry(date: .now, content: .pinned(MemosEntry(date: .now, memos: [], signedIn: false)))
        }
        // Looked up afresh every time: since it was chosen the memo may have been edited,
        // deleted, archived or given a tag that blurs it.
        guard let memo = contents.memos.first(where: { $0.name == id }) else {
            return PinnedEntry(date: .now, content: .unavailable)
        }
        return PinnedEntry(date: .now, content: .memo(memo, sensitive: contents.rules.blurs(memo)))
    }
}

/// A memo you choose, or your pinned memos.
struct PinnedWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Pinned", intent: PinnedWidgetIntent.self, provider: PinnedProvider()) { entry in
            PinnedWidgetView(entry: entry)
                .containerBackground(.paper, for: .widget)
        }
        .configurationDisplayName("Pinned")
        .description("Your pinned memos, or one memo you choose.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PinnedWidgetView: View {
    let entry: PinnedEntry

    var body: some View {
        switch entry.content {
        case .pinned(let list):
            MemoListWidgetView(entry: list, title: "Pinned", systemImage: "pin.fill", empty: "Pin a memo and it shows up here.")
        case .memo(let memo, let sensitive):
            MemoWidgetView(memo: memo, sensitive: sensitive) {
                Label {
                    Text(memo.createdAt, format: .dateTime.month(.abbreviated).day().year())
                } icon: {
                    Image(systemName: memo.pinned ? "pin.fill" : "note.text")
                }
            }
        case .unavailable:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "Pinned", systemImage: "pin.fill")
                WidgetNote("This memo was deleted or archived. Edit the widget to choose another.")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One memo filling the widget, opening it when tapped.
struct MemoWidgetView<Header: View>: View {
    let memo: Memo
    let sensitive: Bool
    @ViewBuilder let header: Header

    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
                .font(.caption.weight(.semibold))
                .foregroundStyle(.ink2)
                .widgetAccentable()
            if sensitive {
                Label("Sensitive content", systemImage: "eye.slash")
                    .font(.footnote)
                    .foregroundStyle(.ink2)
            } else {
                // No line limit: the text takes what room there is and truncates at the bottom.
                Text(InlineText.plain(memo.content, separator: "\n"))
                    .font(family == .systemSmall ? .footnote : .subheadline)
                    .foregroundStyle(.ink)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "memos://memo/\(memo.uid)"))
    }
}
