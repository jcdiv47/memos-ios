import MapKit
import MemosCore
import SwiftUI

/// The activity grid: one square per day, darker for days with more memos. Tap a day to see it.
struct ActivityView: View {
    @Environment(AccountSession.self) private var session
    private let weeks = 26

    var body: some View {
        let calendar = Calendar.current
        let activity = MemoActivity(memos: session.store.own.values, calendar: calendar)
        let today = calendar.startOfDay(for: .now)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 3) {
                        ForEach(activity.weeks(weeks + 1, through: today), id: \.self) { week in
                            VStack(spacing: 3) {
                                ForEach(week, id: \.self) { day in
                                    if day <= today {
                                        let count = activity.count(on: day)
                                        Button {
                                            let next = calendar.date(byAdding: .day, value: 1, to: day)!
                                            session.path.append(.filtered(title: day.formatted(date: .abbreviated, time: .omitted), tokens: [.date(.between(day, next))]))
                                        } label: {
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(count == 0 ? Color.paper2 : Color.memosBlue.opacity(activity.intensity(on: day)))
                                                .frame(width: 14, height: 14)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(count == 0)
                                        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)): \(count) memos")
                                    } else {
                                        Color.clear.frame(width: 14, height: 14)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.timelineInset)
                }
                .defaultScrollAnchor(.trailing)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(monthCounts(calendar: calendar), id: \.month) { entry in
                        HStack {
                            Text(entry.month.formatted(.dateTime.month(.wide).year()))
                                .foregroundStyle(.ink)
                            Spacer()
                            Text("\(entry.count) memos")
                                .foregroundStyle(.ink2)
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                        Divider()
                    }
                }
                .padding(.horizontal, Metrics.timelineInset)
            }
            .padding(.vertical)
        }
        .background(.paper)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
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
                                    .background(.paper2)
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
