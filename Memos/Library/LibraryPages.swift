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
            VStack(alignment: .leading, spacing: 12) {
                stats(activity, today: today)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 6) {
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
                    HStack {
                        Text("Tap a day to see its memos")
                        Spacer(minLength: 8)
                        ActivityLegend()
                    }
                    .font(.caption)
                    .foregroundStyle(.ink2)
                }
                .padding(Metrics.cardPadding)
                .cardBackground()

                let months = monthCounts(calendar: calendar)
                if !months.isEmpty {
                    Text("By month")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ink2)
                        .padding(.leading, 6)
                        .padding(.top, 8)
                    VStack(spacing: 0) {
                        let busiest = months.map(\.count).max() ?? 1
                        ForEach(Array(months.enumerated()), id: \.element.month) { index, entry in
                            if index > 0 {
                                Divider().overlay(.hairline)
                            }
                            HStack(spacing: 12) {
                                Text(entry.month.formatted(.dateTime.month(.wide).year()))
                                    .foregroundStyle(.ink)
                                Spacer(minLength: 8)
                                MonthBar(fraction: Double(entry.count) / Double(busiest))
                                Text(entry.count.formatted())
                                    .foregroundStyle(.ink2)
                                    .monospacedDigit()
                                    .frame(minWidth: 28, alignment: .trailing)
                            }
                            .font(.subheadline)
                            .padding(.vertical, 12)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(entry.month.formatted(.dateTime.month(.wide).year())))
                            .accessibilityValue(Text("\(entry.count) memos"))
                        }
                    }
                    .padding(.horizontal, Metrics.cardPadding)
                    .cardBackground()
                }
            }
            .padding(.horizontal, Metrics.timelineInset)
            .padding(.vertical)
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
        .padding(.vertical, 12)
        .cardBackground()
    }

    private func stat(_ value: Int, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.title2.weight(.semibold))
                .foregroundStyle(.ink)
                .monospacedDigit()
            Text(label)
                .font(.caption)
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
        .font(.caption2)
        .foregroundStyle(.ink2)
        .accessibilityHidden(true)
    }

    private func monthCounts(calendar: Calendar) -> [(month: Date, count: Int)] {
        var counts: [Date: Int] = [:]
        for memo in session.store.own.values where !memo.isArchived {
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: memo.createdAt))!
            counts[month, default: 0] += 1
        }
        return counts.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }
}

/// A month's share of the busiest month, on the activity scale.
private struct MonthBar: View {
    let fraction: Double
    private let width: CGFloat = 72

    var body: some View {
        Capsule()
            .fill(.well)
            .frame(width: width, height: 5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.activity3)
                    .frame(width: max(5, width * fraction))
            }
            .accessibilityHidden(true)
    }
}

/// “Less ▢▢▢▢▢ More”, explaining the grid's steps.
struct ActivityLegend: View {
    var body: some View {
        HStack(spacing: 3) {
            Text(String(localized: "activity.legend.less", defaultValue: "Less", comment: "An end of the activity grid's legend: Less ▢▢▢▢▢ More."))
                .padding(.trailing, 2)
            ForEach(0..<5) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.activity(level: level))
                    .frame(width: 9, height: 9)
            }
            Text(String(localized: "activity.legend.more", defaultValue: "More", comment: "An end of the activity grid's legend: Less ▢▢▢▢▢ More."))
                .padding(.leading, 2)
        }
        .font(.caption2)
        .foregroundStyle(.ink2)
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
                                        .font(.caption2)
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
            let shape = RoundedRectangle(cornerRadius: cell * 0.22)
                .fill(Color.activity(level: activity.level(on: day)))
                .frame(width: cell, height: cell)
                .overlay {
                    if day == today {
                        RoundedRectangle(cornerRadius: cell * 0.22 + 2)
                            .strokeBorder(.ink, lineWidth: 1.25)
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 4)], spacing: 4) {
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
                                    VStack(spacing: 6) {
                                        Image(systemName: item.attachment.systemImage)
                                            .font(.title2)
                                        Text(item.attachment.filename)
                                            .font(.caption2)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                    }
                                    .foregroundStyle(.ink2)
                                    .padding(6)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(.well)
                                }
                            }
                            .clipShape(.rect(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("No attachments", systemImage: "paperclip", description: Text("Photos and files you add to memos collect here."))
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
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(.memosBlue, in: .circle)
                    }
                    .accessibilityLabel(memo.displayTitle)
                }
            }
            UserAnnotation()
        }
        .mapControls { }
        .overlay(alignment: .topTrailing) {
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    MapUserLocationButton(scope: mapScope)
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.circle)
                        .tint(.ink)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                    if session.showsScopeToggle {
                        mapButton(includeOthers ? "person.2.fill" : "person", label: includeOthers ? Text("Showing everyone") : Text("Showing yours")) {
                            includeOthers.toggle()
                        }
                    }
                    mapButton("list.bullet", label: Text("List places")) { showsList = true }
                }
            }
            .padding()
        }
        .mapScope(mapScope)
        .overlay {
            if places.isEmpty {
                ContentUnavailableView("No places yet", systemImage: "map", description: Text("Add a location to a memo from the composer’s paperclip menu."))
                    .padding()
                    .background(.card, in: .rect(cornerRadius: 20))
                    .padding()
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(memo.location.placeholder.isEmpty ? memo.location.latitude.formatted() : memo.location.placeholder)
                                .foregroundStyle(.ink)
                            Text(memo.displayTitle)
                                .font(.metadata)
                                .foregroundStyle(.ink2)
                                .lineLimit(1)
                        }
                    }
                }
                .navigationTitle("Places")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func mapButton(_ systemImage: String, label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(.ink)
                .frame(width: 44, height: 44)
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
                        .padding(.leading, CGFloat(entry.tag.filter { $0 == "/" }.count) * 16)
                    Spacer()
                    Text(entry.count.formatted())
                        .foregroundStyle(.ink2)
                        .monospacedDigit()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.card)
        }
        .scrollContentBackground(.hidden)
        .background(.paper)
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
