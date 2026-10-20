import MemosCore
import SwiftUI

struct RouteDestination: View {
    let route: Route
    let zoom: Namespace.ID

    @Environment(AccountSession.self) private var session

    var body: some View {
        switch route {
        case .memo(let name):
            MemoDetailView(name: name)
                .zoomTransition(from: name, in: zoom)
        case .sharedMemo(let token):
            SharedMemoView(token: token)
        case .library:
            LibraryView(zoom: zoom)
        case .activity:
            ActivityView()
        case .attachments:
            AttachmentsLibraryView()
        case .map:
            PlacesMapView()
        case .tags:
            TagsView()
        case .archived:
            FilteredTimelineView(title: "Archived", filter: nil, state: .archived, zoom: zoom)
        case .view(let name):
            if let view = session.store.profile.views.first(where: { $0.name == name }) {
                FilteredTimelineView(title: view.displayTitle, filter: view.filter, view: view, zoom: zoom)
            } else {
                ContentUnavailableView("View not found", systemImage: "rectangle.stack.badge.minus")
            }
        case .filtered(let title, let tokens):
            FilteredTimelineView(title: title, filter: SearchQuery(tokens: tokens).filter(), zoom: zoom)
        }
    }
}

/// A timeline narrowed by a filter: a saved view, a tag, a day, or the archive. Your matches
/// come from the local copy; other people's from the server when someone else shares.
struct FilteredTimelineView: View {
    let title: String
    let filter: String?
    var state: MemoState = .normal
    var view: MemoView?
    let zoom: Namespace.ID

    @Environment(AccountSession.self) private var session
    @State private var feed = OthersFeed()
    @State private var confirmDeleteView = false
    @Environment(\.dismiss) private var dismiss

    private var parsed: MemoFilter? { filter.flatMap { try? MemoFilter($0) } }

    /// Whether the filter can run on the device. A filter using something only the server
    /// knows (such as `creator_id`) shows server results only.
    private var evaluatesLocally: Bool {
        guard let parsed, let sample = session.store.own.values.first else { return true }
        do {
            _ = try parsed.matches(sample.facts)
            return true
        } catch {
            return false
        }
    }

    private var includesOthers: Bool { state == .normal && session.effectiveScope == .everyone }

    private var memos: [Memo] {
        let scope: MemoQuery.Scope = includesOthers ? .everyone : .mine
        var memos = evaluatesLocally ? session.memos(MemoQuery(scope: scope, filter: parsed, state: state, order: state == .normal && scope == .mine ? .pinnedThenNewest : .newest)) : []
        if !evaluatesLocally {
            memos = feed.serverOnly
        }
        return includesOthers ? feed.visible(memos, online: session.isOnline) : memos
    }

    var body: some View {
        let memos = self.memos
        List {
            if let filter, view != nil {
                Text(filter)
                    .font(.memoCode)
                    .foregroundStyle(.ink2)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(memos, id: \.name) { memo in
                TimelineRow(memo: memo, zoom: zoom)
            }
            if (includesOthers || !evaluatesLocally), feed.hasMore, session.isOnline {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .task(id: memos.count) { await feed.loadMore(using: session.engine, me: session.user, includeOwn: !evaluatesLocally) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.paper)
        .overlay {
            if memos.isEmpty && !feed.isLoading {
                ContentUnavailableView(state == .archived ? "Nothing archived" : "No memos match", systemImage: state == .archived ? "archivebox" : "line.3.horizontal.decrease")
            }
        }
        .navigationTitle(view.map { "\($0.emoji.map { "\($0) " } ?? "")\($0.displayTitle)" } ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await session.engine.sync(fullCompare: true)
            feed.reload()
        }
        .onAppear { feed.reset(to: .init(space: nil, filter: filter)) }
        .toolbar {
            if let view {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New Memo Here", systemImage: "square.and.pencil") {
                            let origin: CaptureOrigin = parsed?.pinnedVisibility.map { .view(space: parsed?.pinnedSpace, visibility: $0) } ?? .timeline(space: parsed?.pinnedSpace)
                            session.capture(origin: origin)
                        }
                        Button("Delete View", systemImage: "trash", role: .destructive) { confirmDeleteView = true }
                            .disabled(!session.isOnline)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .confirmationDialog("Delete “\(view.title)”?", isPresented: $confirmDeleteView, titleVisibility: .visible) {
                        Button("Delete View", role: .destructive) { Task { await deleteView(view) } }
                    } message: {
                        Text("The view is removed on the web too. Its memos stay.")
                    }
                }
            }
        }
    }

    private func deleteView(_ view: MemoView) async {
        var request = Memos_Api_DeleteMemoViewRequest()
        request.name = view.name
        if (try? await session.client.call(session.client.users.deleteMemoView(request:headers:), request)) != nil {
            session.store.profile.views.removeAll { $0.name == view.name }
            dismiss()
        }
    }
}

/// A memo opened from a share link, read-only.
struct SharedMemoView: View {
    let token: String
    @Environment(AccountSession.self) private var session
    @State private var memo: Memo?
    @State private var failed = false

    var body: some View {
        ScrollView {
            if let memo {
                VStack(alignment: .leading, spacing: 14) {
                    MemoHeader(memo: memo)
                    MemoContentView(content: memo.content)
                    AttachmentGallery(attachments: memo.attachments)
                }
                .padding(Metrics.timelineInset)
            } else if failed {
                ContentUnavailableView("Link unavailable", systemImage: "link", description: Text("The share link expired or was revoked."))
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .background(.paper)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            var request = Memos_Api_GetSharedMemoRequest()
            request.shareToken = token
            do {
                memo = try await session.client.callPublic(session.client.memos.getSharedMemo(request:headers:), request)
            } catch {
                failed = true
            }
        }
    }
}
