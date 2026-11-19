import AppIntents
import MemosCore
import SwiftUI
import WidgetKit

@main
struct MemosWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickCaptureWidget()
        PinnedWidget()
        MemoryWidget()
        OnThisDayWidget()
        ActivityWidget()
        NewMemoControl()
        VoiceMemoControl()
    }
}

// MARK: Timeline

/// The signed-in account's memos, read from the local copy in the shared container.
enum WidgetStore {
    struct Contents: Sendable {
        /// Your memos that aren't archived.
        var memos: [Memo]
        var rules: TagBlurRules
    }

    /// Nil when signed out.
    static func load() async -> Contents? {
        guard let location = AccountLocation.current else { return nil }
        let memos = await AccountArchive.readOwnMemos(location).filter { $0.state == .normal }
        let rules = await AccountArchive.readProfile(location).tagBlurRules
        return Contents(memos: memos, rules: rules)
    }
}

struct MemosEntry: TimelineEntry {
    var date: Date
    var memos: [Memo]
    var signedIn: Bool
    /// Memos whose tags are set to blur, shown without their text.
    var sensitive: Set<String> = []
}

/// Reads the app's local copy from the shared container; widgets never call the server.
struct MemosProvider: TimelineProvider {
    enum Kind { case none, pinned, onThisDay }
    let kind: Kind

    func placeholder(in context: Context) -> MemosEntry {
        MemosEntry(date: .now, memos: Self.samples, signedIn: true)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (MemosEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        let kind = self.kind
        Task { completion(await Self.entry(kind: kind)) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<MemosEntry>) -> Void) {
        let kind = self.kind
        Task {
            let entry = await Self.entry(kind: kind)
            // On this day changes at midnight; pinned memos change when the app reloads widgets.
            let next = Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400))
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    static func entry(kind: Kind) async -> MemosEntry {
        guard let contents = await WidgetStore.load() else {
            return MemosEntry(date: .now, memos: [], signedIn: false)
        }
        let memos = contents.memos
        let calendar = Calendar.current
        let today = calendar.dateComponents([.month, .day, .year], from: .now)
        let selected: [Memo]
        switch kind {
        case .none:
            selected = []
        case .pinned:
            selected = memos.filter(\.pinned).sorted { $0.createdAt > $1.createdAt }
        case .onThisDay:
            selected = memos.filter { memo in
                let parts = calendar.dateComponents([.month, .day, .year], from: memo.createdAt)
                return parts.month == today.month && parts.day == today.day && parts.year != today.year
            }
            .sorted { $0.createdAt > $1.createdAt }
        }
        let shown = Array(selected.prefix(6))
        return MemosEntry(date: .now, memos: shown, signedIn: true, sensitive: Set(shown.filter(contents.rules.blurs).map(\.name)))
    }

    /// Shown in the widget gallery, so they're in the reader's language.
    static let samples: [Memo] = [
        String(localized: "Morning light over the harbor. #walks", comment: "A sample memo in the widget gallery. Translate the tag too."),
        String(localized: "Write the changelog", comment: "A sample memo in the widget gallery."),
        String(localized: "Repotted the monstera. #plants", comment: "A sample memo in the widget gallery. Translate the tag too."),
    ].enumerated().map { index, text in
        var memo = Memo()
        // By position: translations can share a length.
        memo.name = "memos/sample-\(index)"
        memo.content = text
        return memo
    }
}

// MARK: Widgets

/// Small: a capture field and a mic, like the bottom bar.
struct QuickCaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuickCapture", provider: MemosProvider(kind: .none)) { _ in
            QuickCaptureView()
                .containerBackground(.paper, for: .widget)
        }
        .configurationDisplayName("Quick Capture")
        .description("Start a memo from your Home Screen.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct QuickCaptureView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: "square.and.pencil")
                .font(.title2)
                .widgetAccentable()
                .widgetURL(URL(string: "memos://new"))
        case .accessoryRectangular:
            Label("Capture a thought", systemImage: "square.and.pencil")
                .widgetAccentable()
                .widgetURL(URL(string: "memos://new"))
        default:
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("Memos")
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(.ink)
                Spacer()
                Link(destination: URL(string: "memos://new")!) {
                    HStack {
                        Text("Capture…")
                            .font(.subheadline)
                            .foregroundStyle(.ink2)
                        Spacer()
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(.memosBlue)
                            .widgetAccentable()
                    }
                    .padding(Spacing.l)
                    .background(.card, in: .capsule)
                }
                Link(destination: URL(string: "memos://voice")!) {
                    Label("Voice memo", systemImage: "mic")
                        .font(.footnote)
                        .foregroundStyle(.memosBlue)
                        .widgetAccentable()
                }
            }
        }
    }
}

/// Large: what you wrote on this day in earlier years.
struct OnThisDayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OnThisDay", provider: MemosProvider(kind: .onThisDay)) { entry in
            MemoListWidgetView(entry: entry, title: "On this day", systemImage: "calendar", empty: "Nothing from this day in earlier years yet.")
                .containerBackground(.paper, for: .widget)
        }
        .configurationDisplayName("On This Day")
        .description("Memos from this day in earlier years.")
        .supportedFamilies([.systemLarge, .systemMedium])
    }
}

struct MemoListWidgetView: View {
    let entry: MemosEntry
    let title: LocalizedStringKey
    let systemImage: String
    let empty: LocalizedStringKey

    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            WidgetHeader(title: title, systemImage: systemImage)
            if !entry.signedIn {
                WidgetNote("Open Memos and sign in.")
            } else if entry.memos.isEmpty {
                WidgetNote(empty)
            } else {
                ForEach(entry.memos.prefix(shownCount), id: \.name) { memo in
                    Link(destination: URL(string: "memos://memo/\(memo.uid)")!) {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            if entry.sensitive.contains(memo.name) {
                                Label("Sensitive content", systemImage: "eye.slash")
                                    .font(.footnote)
                                    .foregroundStyle(.ink2)
                            } else {
                                Text(InlineText.plain(memo.content))
                                    .font(.footnote)
                                    .foregroundStyle(.ink)
                                    .lineLimit(family == .systemMedium ? 2 : 3)
                            }
                            Text(memo.createdAt, format: .dateTime.month(.abbreviated).day().year())
                                .font(.caption2)
                                .foregroundStyle(.ink2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.m)
                        .background(.card, in: .rect(cornerRadius: Radius.inner))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        // Small widgets have one tap target, so the link above doesn't work there.
        .widgetURL(family == .systemSmall ? entry.memos.first.flatMap { URL(string: "memos://memo/\($0.uid)") } : nil)
    }

    private var shownCount: Int {
        switch family {
        case .systemSmall: 1
        case .systemMedium: 2
        default: 5
        }
    }
}

/// A widget's title line.
struct WidgetHeader: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(.subheadline, design: .serif).weight(.semibold))
            .foregroundStyle(.ink)
            .widgetAccentable()
    }
}

/// An empty or signed-out state, under the header.
struct WidgetNote: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.ink2)
    }
}

nonisolated enum InlineText {
    /// A memo's text without Markdown markers: on as few lines as possible, or one paragraph per
    /// line when the separator is a newline.
    static func plain(_ content: String, separator: String = " · ") -> String {
        content
            .replacingOccurrences(of: "- [ ] ", with: "☐ ")
            .replacingOccurrences(of: "- [x] ", with: "☑ ")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>*- ")) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }
}

// MARK: Controls

/// Control Center, the Lock Screen and the Action button.
struct NewMemoControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "NewMemoControl") {
            ControlWidgetButton(action: NewMemoIntent()) {
                Label("New Memo", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Memo")
        .description("Opens Memos to write a new memo.")
    }
}

struct VoiceMemoControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "VoiceMemoControl") {
            ControlWidgetButton(action: VoiceMemoIntent()) {
                Label("Voice Memo", systemImage: "mic")
            }
        }
        .displayName("Voice Memo")
        .description("Records a private voice memo.")
    }
}
