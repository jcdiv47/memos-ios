import MemosCore
import SwiftUI

/// Library gathers the web sidebar's secondary pages, which all browse the same memos in
/// different ways: the activity grid first, then attachments, the map, tags, the archive and
/// saved views.
struct LibraryView: View {
    @Environment(AccountSession.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var symbolScale = SymbolScale.base

    private var stats: LibraryStats { LibraryStats(memos: Array(session.store.own.values)) }

    var body: some View {
        let stats = self.stats
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.cardGap) {
                ActivityCard(stats: stats)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.cardGap), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: Metrics.cardGap) {
                    tile(.attachments, title: "Attachments", detail: stats.attachmentCount.formatted(), systemImage: "paperclip", isEmpty: stats.attachmentCount == 0)
                    tile(.map, title: "Map", detail: stats.placeCount == 0 ? String(localized: "No places") : String(localized: "\(stats.placeCount) places"), systemImage: "map", isEmpty: stats.placeCount == 0)
                    tile(.tags, title: "Tags", detail: stats.tagCount.formatted(), systemImage: "number", isEmpty: stats.tagCount == 0)
                    tile(.archived, title: "Archived", detail: stats.archivedCount.formatted(), systemImage: "archivebox", isEmpty: stats.archivedCount == 0)
                }

                SectionHeader("Saved views")

                CardList(dividerInset: Metrics.iconRowTextInset) {
                    if session.store.profile.views.isEmpty {
                        Text("Save a search as a view and it appears here and on the web.")
                            .font(.supporting)
                            .foregroundStyle(.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Metrics.rowPadding)
                    }
                    ForEach(session.store.profile.views, id: \.name) { view in
                        Button {
                            session.path.append(.view(view.name))
                        } label: {
                            SavedViewRow(view: view)
                        }
                        .buttonStyle(.plain)
                    }
                    // Views are saved from search, so this opens it.
                    Button(action: openSearch) {
                        // The symbol takes an emoji's column, so the text lines up with the views above.
                        HStack(spacing: Spacing.l) {
                            Image(systemName: "plus")
                                .font(.rowSymbol)
                                .frame(width: Metrics.scaled(Metrics.iconTile, by: symbolScale))
                            Text("New saved view")
                                .font(.rowTitle)
                        }
                        .foregroundStyle(.memosBlue)
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget, alignment: .leading)
                        .padding(.vertical, Spacing.xs)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Metrics.screenInset)
            .padding(.bottom, Metrics.screenInset)
            .readableWidth()
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
            // A tight gap: on the narrowest phones, such as iPhone Duo, two tiles share about 340
            // points and “Attachments” needs every one.
            HStack(spacing: Spacing.m) {
                IconTile(systemImage: systemImage, isEmpty: isEmpty)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title)
                        .font(.emphasis)
                        .foregroundStyle(.ink)
                    Text(detail)
                        .font(.metadata)
                        .foregroundStyle(isEmpty ? Color.ink3 : Color.ink2)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.9)
                Spacer(minLength: 0)
            }
            .padding(Spacing.l)
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
            VStack(alignment: .leading, spacing: Metrics.blockGap) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Activity")
                        .font(.emphasis)
                        .foregroundStyle(.ink)
                    Spacer(minLength: Spacing.m)
                    Text(summary)
                        .font(.metadata)
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
                // The legend moves under the count when they don't fit side by side.
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("\(activity.memoCount(inMonthOf: today)) this month")
                            .monospacedDigit()
                        Spacer(minLength: Spacing.m)
                        ActivityLegend()
                    }
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("\(activity.memoCount(inMonthOf: today)) this month")
                            .monospacedDigit()
                        ActivityLegend()
                    }
                }
                .font(.legend)
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

private struct SavedViewRow: View {
    let view: MemoView
    @Environment(AccountSession.self) private var session
    @ScaledMetric(relativeTo: .subheadline) private var symbolScale = SymbolScale.base

    var body: some View {
        HStack(spacing: Spacing.l) {
            Text(view.emoji ?? "🔖")
                .font(.title3)
                .frame(width: Metrics.scaled(Metrics.iconTile, by: symbolScale))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(view.displayTitle)
                    .font(.rowTitle)
                    .foregroundStyle(.ink)
                Text(view.filter)
                    .font(.fineCode)
                    .foregroundStyle(.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.m)
            if let count {
                Text(count.formatted())
                    .font(.rowTitle)
                    .foregroundStyle(.ink2)
                    .monospacedDigit()
            }
            Chevron()
        }
        .padding(.vertical, Spacing.l)
        .contentShape(.rect)
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
