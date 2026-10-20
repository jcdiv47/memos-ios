import MemosCore
import SwiftUI

/// Library gathers the web sidebar's secondary pages, which all browse the same memos in
/// different ways: the activity grid, attachments, the map, tags, the archive and saved views.
struct LibraryView: View {
    let zoom: Namespace.ID

    @Environment(AccountSession.self) private var session

    private var stats: LibraryStats { LibraryStats(memos: Array(session.store.own.values)) }

    var body: some View {
        let stats = self.stats
        List {
            Section {
                row(.activity, title: "Activity", detail: "\(stats.memoCount.formatted()) memos · \(stats.dayCount.formatted()) days", systemImage: "calendar")
                row(.attachments, title: "Attachments", detail: stats.attachmentCount.formatted(), systemImage: "paperclip")
                row(.map, title: "Map", detail: stats.placeCount == 1 ? "1 place" : "\(stats.placeCount.formatted()) places", systemImage: "map")
                row(.tags, title: "Tags", detail: stats.tagCount.formatted(), systemImage: "number")
                row(.archived, title: "Archived", detail: stats.archivedCount.formatted(), systemImage: "archivebox")
            }
            .listRowBackground(Color.card)

            Section {
                if session.store.profile.views.isEmpty {
                    Text("Save a search as a view and it appears here and on the web.")
                        .font(.subheadline)
                        .foregroundStyle(.ink2)
                }
                ForEach(session.store.profile.views, id: \.name) { view in
                    Button {
                        session.path.append(.view(view.name))
                    } label: {
                        SavedViewRow(view: view)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Saved views")
            }
            .listRowBackground(Color.card)
        }
        .scrollContentBackground(.hidden)
        .background(.paper)
        .navigationTitle("Library")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    session.isSettingsPresented = true
                } label: {
                    Avatar(name: session.store.profile.user?.displayLabel ?? "Y", size: 30)
                }
                .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .bottomBar) {
                CaptureField(zoom: zoom)
            }
        }
    }

    private func row(_ route: Route, title: String, detail: String, systemImage: String) -> some View {
        Button {
            session.path.append(route)
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.ink)
                Spacer()
                Text(detail)
                    .foregroundStyle(.ink2)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.hairline)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
                Text(view.filter)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.ink2)
                    .lineLimit(1)
            }
            Spacer()
            if let count {
                Text(count.formatted())
                    .foregroundStyle(.ink2)
                    .monospacedDigit()
            }
        }
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
