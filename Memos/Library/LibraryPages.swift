import MapKit
import MemosCore
import SwiftUI

/// The activity grid with its dates, a summary above and memos by month below. Tap a day to see it.
struct ActivityView: View {
    @Environment(AccountSession.self) private var session
    private let weeks = 26

    var body: some View {
        let calendar = Calendar.current
        let activity = MemoActivity(memos: session.store.own.values, calendar: calendar)
        let today = calendar.startOfDay(for: .now)

        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.cardGap) {
                stats(activity, today: today)

                VStack(alignment: .leading, spacing: Metrics.blockGap) {
                    HStack(alignment: .top, spacing: Spacing.s) {
                        weekdayLabels(calendar: calendar)
                        ScrollView(.horizontal, showsIndicators: false) {
                            ActivityHeatmap(activity: activity, today: today, weeks: weeks + 1, showsMonths: true) { day in
                                let next = calendar.date(byAdding: .day, value: 1, to: day)!
                                session.path.append(.filtered(title: day.formatted(date: .abbreviated, time: .omitted), tokens: [.date(.between(day, next))]))
                            }
                            // Room for today's ring.
                            .padding(3)
                        }
                        .defaultScrollAnchor(.trailing)
                        .padding(-3)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text("Tap a day to see its memos")
                            Spacer(minLength: Spacing.m)
                            ActivityLegend()
                        }
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            Text("Tap a day to see its memos")
                            ActivityLegend()
                        }
                    }
                    .font(.legend)
                    .foregroundStyle(.ink2)
                }
                .padding(Metrics.cardPadding)
                .cardBackground()

                let years = monthCounts(calendar: calendar, through: today)
                let busiest = years.flatMap(\.months).map(\.count).max() ?? 1
                ForEach(years, id: \.year) { year in
                    SectionHeader(verbatim: year.year.formatted(.dateTime.year())) {
                        Text("\(year.months.map(\.count).reduce(0, +)) memos")
                    }
                    CardList {
                        ForEach(year.months, id: \.month) { entry in
                            monthRow(entry.month, count: entry.count, busiest: busiest, calendar: calendar)
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.screenInset)
            .padding(.vertical, Metrics.screenInset)
            .readableWidth()
        }
        .background(.paper)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stats(_ activity: MemoActivity, today: Date) -> some View {
        HStack(spacing: 0) {
            stat(activity.memoCount(inMonthOf: today), label: "This month")
            Divider().overlay(.hairline)
            stat(activity.streak(through: today), label: "Day streak")
            Divider().overlay(.hairline)
            stat(activity.counts.count, label: "Active days")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Spacing.l)
        .cardBackground()
    }

    private func stat(_ value: Int, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(value.formatted())
                .font(.stat)
                .foregroundStyle(.ink)
                .monospacedDigit()
            Text(label)
                .font(.legend)
                .foregroundStyle(.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.cardPadding)
        .accessibilityElement(children: .combine)
    }

    /// Every other weekday, beside the grid's rows, under a gap the height of the month row.
    private func weekdayLabels(calendar: Calendar) -> some View {
        VStack(alignment: .leading, spacing: ActivityHeatmap.spacing) {
            Color.clear.frame(width: 0, height: ActivityHeatmap.monthRowHeight)
            ForEach(0..<7, id: \.self) { row in
                Text(row % 2 == 1 ? calendar.shortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + row) % 7] : "")
                    .frame(height: ActivityHeatmap.cell)
            }
        }
        .font(.fine)
        .foregroundStyle(.ink2)
        .accessibilityHidden(true)
    }

    /// A row that opens the month's memos; empty months stay, dimmed, so gaps read as gaps.
    private func monthRow(_ month: Date, count: Int, busiest: Int, calendar: Calendar) -> some View {
        Button {
            let next = calendar.date(byAdding: .month, value: 1, to: month)!
            session.path.append(.filtered(title: month.formatted(.dateTime.month(.wide).year()), tokens: [.date(.between(month, next))]))
        } label: {
            HStack(spacing: Spacing.l) {
                Text(month.formatted(.dateTime.month(.wide)))
                    .foregroundStyle(count == 0 ? Color.ink3 : Color.ink)
                    .frame(minWidth: 96, alignment: .leading)
                MonthBar(fraction: Double(count) / Double(busiest))
                Text(count.formatted())
                    .foregroundStyle(count == 0 ? Color.ink3 : Color.ink2)
                    .monospacedDigit()
                    .frame(minWidth: 24, alignment: .trailing)
                Chevron()
                    .opacity(count == 0 ? 0 : 1)
            }
            .font(.supporting)
            .padding(.vertical, Metrics.rowPadding)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(month.formatted(.dateTime.month(.wide).year())))
        .accessibilityValue(Text("\(count) memos"))
        .accessibilityAddTraits(.isButton)
    }

    /// Every month from your first memo through this one, newest first, grouped by year.
    private func monthCounts(calendar: Calendar, through today: Date) -> [(year: Date, months: [(month: Date, count: Int)])] {
        var counts: [Date: Int] = [:]
        for memo in session.store.own.values where !memo.isArchived {
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: memo.createdAt))!
            counts[month, default: 0] += 1
        }
        guard let first = counts.keys.min() else { return [] }
        let current = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
        var months: [(month: Date, count: Int)] = []
        var month = max(current, counts.keys.max()!)
        while month >= first {
            months.append((month, counts[month] ?? 0))
            month = calendar.date(byAdding: .month, value: -1, to: month)!
        }
        let years = Dictionary(grouping: months) { calendar.date(from: calendar.dateComponents([.year], from: $0.month))! }
        return years.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }
}

/// A month's share of the busiest month, on the activity scale, filling the row's free width.
private struct MonthBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.well)
                .overlay(alignment: .leading) {
                    if fraction > 0 {
                        Capsule()
                            .fill(.activity3)
                            .frame(width: max(6, proxy.size.width * fraction))
                    }
                }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// “Less ▢▢▢▢▢ More”, explaining the grid's steps.
struct ActivityLegend: View {
    var body: some View {
        HStack(spacing: ActivityHeatmap.spacing) {
            Text(String(localized: "activity.legend.less", defaultValue: "Less", comment: "An end of the activity grid's legend: Less ▢▢▢▢▢ More."))
                .padding(.trailing, Spacing.xxs)
            ForEach(0..<5) { level in
                RoundedRectangle(cornerRadius: 9 * ActivityHeatmap.cornerFraction)
                    .fill(Color.activity(level: level))
                    .frame(width: 9, height: 9)
            }
            Text(String(localized: "activity.legend.more", defaultValue: "More", comment: "An end of the activity grid's legend: Less ▢▢▢▢▢ More."))
                .padding(.leading, Spacing.xxs)
        }
        .font(.fine)
        .foregroundStyle(.ink2)
        // Never breaks a word; the row around it moves the legend to its own line instead.
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// One square per day and a column per week, newest on the right; days after today stay blank.
/// With `onSelect`, active days are buttons.
struct ActivityHeatmap: View {
    let activity: MemoActivity
    let today: Date
    let weeks: Int
    var cell: CGFloat = Self.cell
    var showsMonths = false
    var onSelect: ((Date) -> Void)?

    static let cell: CGFloat = 14
    static let spacing: CGFloat = 3
    static let monthRowHeight: CGFloat = 14
    /// A square's corner as a share of its side, so squares of any size look alike.
    static let cornerFraction: CGFloat = 0.22

    var body: some View {
        let columns = activity.weeks(weeks, through: today)
        let labels = monthLabels(columns)
        HStack(alignment: .top, spacing: Self.spacing) {
            ForEach(Array(columns.enumerated()), id: \.element) { index, week in
                VStack(spacing: Self.spacing) {
                    if showsMonths {
                        Color.clear
                            .frame(width: cell, height: Self.monthRowHeight)
                            .overlay(alignment: .leading) {
                                if let month = labels[index] {
                                    Text(month.formatted(.dateTime.month(.abbreviated)))
                                        .font(.fine)
                                        .foregroundStyle(.ink2)
                                        .fixedSize()
                                }
                            }
                    }
                    ForEach(week, id: \.self) { day in
                        square(day)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func square(_ day: Date) -> some View {
        if day > today {
            Color.clear.frame(width: cell, height: cell)
        } else {
            let count = activity.count(on: day)
            let shape = RoundedRectangle(cornerRadius: cell * Self.cornerFraction)
                .fill(Color.activity(level: activity.level(on: day)))
                .frame(width: cell, height: cell)
                .overlay {
                    if day == today {
                        RoundedRectangle(cornerRadius: cell * Self.cornerFraction + 2)
                            .strokeBorder(.ink, lineWidth: Stroke.emphasized)
                            .padding(-2.5)
                    }
                }
            if let onSelect {
                Button { onSelect(day) } label: { shape }
                    .buttonStyle(.plain)
                    .disabled(count == 0)
                    .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)): \(count) memos")
            } else {
                shape
            }
        }
    }

    /// The month above each column that holds a month's first day, and above the first column
    /// when the next label is far enough away not to collide with it.
    private func monthLabels(_ columns: [[Date]]) -> [Date?] {
        let calendar = Calendar.current
        var labels: [Date?] = columns.map { week in
            week.first { calendar.component(.day, from: $0) == 1 }
        }
        if let first = columns.first?.last, !labels.prefix(3).contains(where: { $0 != nil }) {
            labels[0] = first
        }
        return labels
    }
}

/// Every attachment across your memos, newest first.
struct AttachmentsLibraryView: View {
    @Environment(AccountSession.self) private var session
    @State private var previewURL: URL?

    var body: some View {
        let items = session.store.own.values
            .filter { !$0.isArchived }
            .flatMap { memo in memo.attachments.map { (memo: memo, attachment: $0) } }
            .sorted { $0.memo.createdAt > $1.memo.createdAt }
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: Spacing.xs)], spacing: Spacing.xs) {
                ForEach(items, id: \.attachment.name) { item in
                    Button {
                        session.path.append(.memo(item.memo.name))
                    } label: {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                if item.attachment.isImage {
                                    AttachmentImage(attachment: item.attachment)
                                } else {
                                    VStack(spacing: Spacing.s) {
                                        Image(systemName: item.attachment.systemImage)
                                            .font(.title2)
                                        Text(item.attachment.filename)
                                            .font(.fine)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                    }
                                    .foregroundStyle(.ink2)
                                    .padding(Spacing.s)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(.well)
                                }
                            }
                            // From a memo your tags blur: blurred as on its card, file names too.
                            .blur(radius: session.isHidden(item.memo) ? 16 : 0, opaque: true)
                            .clipShape(.rect(cornerRadius: Radius.tight))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(session.isHidden(item.memo) ? Text("Sensitive content") : Text(verbatim: item.attachment.filename))
                }
            }
            .padding(Spacing.xs)
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("No attachments", systemImage: "paperclip")
            }
        }
        .background(.paper)
        .navigationTitle("Attachments")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The memos that have a place, on a map. The floating controls are hand-placed glass.
struct PlacesMapView: View {
    @Environment(AccountSession.self) private var session
    @State private var position: MapCameraPosition = .automatic
    @State private var showsList = false
    @State private var includeOthers = false
    @Namespace private var mapScope
    /// The places list grows out of its button.
    @Namespace private var listButton

    private var places: [Memo] {
        let scope: MemoQuery.Scope = includeOthers && session.showsScopeToggle ? .everyone : .mine
        return session.memos(MemoQuery(scope: scope, filter: try? MemoFilter("has_location"), order: .newest))
    }

    var body: some View {
        let places = self.places
        Map(position: $position, scope: mapScope) {
            ForEach(places, id: \.name) { memo in
                Annotation(memo.location.placeholder, coordinate: CLLocationCoordinate2D(latitude: memo.location.latitude, longitude: memo.location.longitude)) {
                    Button {
                        session.path.append(.memo(memo.name))
                    } label: {
                        Image(systemName: "note.text")
                            .font(.metadata.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(Spacing.m)
                            .background(.memosBlue, in: .circle)
                    }
                    .accessibilityLabel(session.redactedTitle(of: memo))
                }
            }
            UserAnnotation()
        }
        .mapControls { }
        .overlay(alignment: .topTrailing) {
            GlassEffectContainer(spacing: Spacing.l) {
                VStack(spacing: Spacing.l) {
                    MapUserLocationButton(scope: mapScope)
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.circle)
                        .tint(.ink)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .glassEffect(.regular.interactive(), in: .circle)
                    if session.showsScopeToggle {
                        mapButton(includeOthers ? "person.2.fill" : "person", label: includeOthers ? Text("Showing everyone") : Text("Showing yours")) {
                            withAnimation(.memosSpring) { includeOthers.toggle() }
                        }
                    }
                    mapButton("list.bullet", label: Text("List places")) { showsList = true }
                        .matchedTransitionSource(id: "map.list", in: listButton)
                }
            }
            .padding(Metrics.screenInset)
        }
        .mapScope(mapScope)
        .overlay {
            if places.isEmpty {
                ContentUnavailableView("No places yet", systemImage: "map")
                    .padding(Spacing.xl)
                    .background(.card, in: .rect(cornerRadius: Radius.panel))
                    .padding(Metrics.screenInset)
            }
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsList) {
            NavigationStack {
                List(places, id: \.name) { memo in
                    Button {
                        showsList = false
                        session.path.append(.memo(memo.name))
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(memo.location.placeholder.isEmpty ? memo.location.latitude.formatted() : memo.location.placeholder)
                                .foregroundStyle(.ink)
                            Text(session.redactedTitle(of: memo))
                                .font(.metadata)
                                .foregroundStyle(.ink2)
                                .lineLimit(1)
                        }
                    }
                    .cardRows()
                }
                .paperBackground()
                .navigationTitle("Places")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
            .zoomTransition(from: "map.list", in: listButton)
        }
    }

    private func mapButton(_ systemImage: String, label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(.ink)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// Your tags with how many memos carry each.
struct TagsView: View {
    @Environment(AccountSession.self) private var session
    @State private var filter = ""

    var body: some View {
        let tags = session.store.tagCounts().filter { filter.isEmpty || $0.tag.localizedCaseInsensitiveContains(filter) }
        List(tags, id: \.tag) { entry in
            Button {
                session.path.append(.filtered(title: "#\(entry.tag)", tokens: [.tag(entry.tag)]))
            } label: {
                HStack {
                    Text(verbatim: "#\(entry.tag)")
                        .foregroundStyle(.memosBlue)
                        .padding(.leading, CGFloat(entry.tag.filter { $0 == "/" }.count) * Spacing.xl)
                    Spacer()
                    Text(entry.count.formatted())
                        .foregroundStyle(.ink2)
                        .monospacedDigit()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .cardRows()
        }
        .paperBackground()
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter tags")
        .overlay {
            if tags.isEmpty {
                ContentUnavailableView("No tags", systemImage: "number", description: Text("Type # in a memo to tag it."))
            }
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
    }
}
