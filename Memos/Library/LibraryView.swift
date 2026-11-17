import MemosCore
import SwiftUI

/// Library gathers the web sidebar's secondary pages, which all browse the same memos in
/// different ways: the activity grid first, then attachments, the map, tags, the archive and
/// saved views.
struct LibraryView: View {
    @Environment(AccountSession.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var stats: LibraryStats { LibraryStats(memos: Array(session.store.own.values)) }

    var body: some View {
        let stats = self.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ActivityCard(stats: stats)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                    tile(.attachments, title: "Attachments", detail: stats.attachmentCount.formatted(), systemImage: "paperclip", isEmpty: stats.attachmentCount == 0)
                    tile(.map, title: "Map", detail: stats.placeCount == 0 ? String(localized: "No places") : String(localized: "\(stats.placeCount) places"), systemImage: "map", isEmpty: stats.placeCount == 0)
                    tile(.tags, title: "Tags", detail: stats.tagCount.formatted(), systemImage: "number", isEmpty: stats.tagCount == 0)
                    tile(.archived, title: "Archived", detail: stats.archivedCount.formatted(), systemImage: "archivebox", isEmpty: stats.archivedCount == 0)
                }

                Text("Saved views")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ink2)
                    .padding(.leading, 6)
                    .padding(.top, 10)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 0) {
                    if session.store.profile.views.isEmpty {
                        Text("Save a search as a view and it appears here and on the web.")
                            .font(.subheadline)
                            .foregroundStyle(.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                        Divider().overlay(.hairline)
                    }
                    ForEach(session.store.profile.views, id: \.name) { view in
                        Button {
                            session.path.append(.view(view.name))
                        } label: {
                            SavedViewRow(view: view)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(.hairline)
                    }
                    // Views are saved from search, so this opens it.
                    Button(action: openSearch) {
                        Label("New saved view", systemImage: "plus")
                            .foregroundStyle(.memosBlue)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Metrics.cardPadding)
                .cardBackground()
            }
            .padding(.horizontal, Metrics.timelineInset)
            .padding(.bottom)
        }
        .background(.paper)
        .navigationTitle("Library")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            // The timeline's bottom row: capture, then Search.
            ToolbarItem(placement: .bottomBar) {
                CaptureField()
            }
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button(action: openSearch) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.ink)
                }
                .accessibilityLabel("Search")
            }
        }
    }

    /// Search lives on the timeline, so go back to it and open search there.
    private func openSearch() {
        session.path.removeAll()
        session.pendingSearch = SearchQuery(text: "")
    }

    private func tile(_ route: Route, title: LocalizedStringKey, detail: String, systemImage: String, isEmpty: Bool) -> some View {
        Button {
            session.path.append(route)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isEmpty ? Color.ink3 : Color.memosBlue)
                    .frame(width: 32, height: 32)
                    .background(isEmpty ? Color.well : Color.memosBlue.opacity(0.12), in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ink)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(isEmpty ? Color.ink3 : Color.ink2)
                        .monospacedDigit()
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(12)
            .cardBackground()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The last weeks of the activity grid, as many as fit, with this month's count and the legend.
/// Opens Activity.
private struct ActivityCard: View {
    let stats: LibraryStats
    @Environment(AccountSession.self) private var session

    var body: some View {
        let calendar = Calendar.current
        let activity = MemoActivity(memos: session.store.own.values, calendar: calendar)
        let today = calendar.startOfDay(for: .now)
        let summary = [String(localized: "\(stats.memoCount) memos"), String(localized: "\(stats.dayCount) days")].joined(separator: " · ")
        Button {
            session.path.append(.activity)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Activity")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ink)
                    Spacer(minLength: 8)
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.ink2)
                        .monospacedDigit()
                    Chevron()
                }
                // Squares as close to the Activity screen's as fit the width exactly.
                GeometryReader { proxy in
                    let spacing = ActivityHeatmap.spacing
                    let weeks = max(Int((proxy.size.width + spacing) / (ActivityHeatmap.cell + spacing)), 1)
                    let cell = (proxy.size.width - spacing * CGFloat(weeks - 1)) / CGFloat(weeks)
                    ActivityHeatmap(activity: activity, today: today, weeks: weeks, cell: cell)
                }
                .frame(height: ActivityHeatmap.cell * 7 + ActivityHeatmap.spacing * 6)
                HStack {
                    Text("\(activity.memoCount(inMonthOf: today)) this month")
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    ActivityLegend()
                }
                .font(.caption)
                .foregroundStyle(.ink2)
            }
            .padding(Metrics.cardPadding)
            .cardBackground()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity")
        .accessibilityValue(summary)
        .accessibilityAddTraits(.isButton)
    }
}

/// The trailing chevron on rows that open a page.
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.ink3)
            .accessibilityHidden(true)
    }
}

private struct SavedViewRow: View {
    let view: MemoView
    @Environment(AccountSession.self) private var session

    var body: some View {
        HStack(spacing: 12) {
            Text(view.emoji ?? "🔖")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(view.displayTitle)
                    .foregroundStyle(.ink)
                description
                    .foregroundStyle(.ink2)
                    .lineLimit(1)
            }
            Spacer()
            if let count {
                Text(count.formatted())
                    .foregroundStyle(.ink2)
                    .monospacedDigit()
            }
            Chevron()
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
    }

    /// “#idea · Pinned” when the filter is one search could have built, the filter itself
    /// otherwise.
    @ViewBuilder
    private var description: some View {
        if let summary = session.summary(ofFilter: view.filter) {
            // A view named for its filter, like “Open tasks”, needs no second line.
            if summary.localizedCaseInsensitiveCompare(view.displayTitle) != .orderedSame {
                Text(summary)
                    .font(.footnote)
            }
        } else {
            Text(view.filter)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private var count: Int? {
        guard let filter = try? MemoFilter(view.filter) else { return nil }
        return session.memos(MemoQuery(scope: .mine, filter: filter)).count
    }
}

struct LibraryStats {
    var memoCount = 0
    var dayCount = 0
    var attachmentCount = 0
    var placeCount = 0
    var tagCount = 0
    var archivedCount = 0

    init(memos: [Memo], calendar: Calendar = .current) {
        var days: Set<DateComponents> = []
        var tags: Set<String> = []
        for memo in memos {
            if memo.isArchived {
                archivedCount += 1
                continue
            }
            memoCount += 1
            days.insert(calendar.dateComponents([.year, .month, .day], from: memo.createdAt))
            attachmentCount += memo.attachments.count
            if memo.hasLocation { placeCount += 1 }
            tags.formUnion(memo.facts.tags)
        }
        dayCount = days.count
        tagCount = tags.count
    }
}

extension AccountSession {
    /// A saved view's filter in words, “#idea · Pinned”, when search could have built it.
    func summary(ofFilter filter: String) -> String? {
        guard let tokens = (try? MemoFilter(filter))?.tokens(spaceTitle: { self.space(named: $0)?.title }), !tokens.isEmpty else { return nil }
        return tokens.map(\.label).joined(separator: " · ")
    }
}
