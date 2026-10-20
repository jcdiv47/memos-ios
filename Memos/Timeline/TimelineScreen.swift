import MemosCore
import SwiftUI

/// Home. One glass row at the top (the title with its Space menu, the filter and Inbox buttons)
/// and one at the bottom (Library, the capture field and Search). Memos pass under both.
struct TimelineScreen: View {
    /// False when an enclosing split view presents the composer, Inbox and Settings itself.
    var presentsSheets = true

    @Environment(AccountSession.self) private var session
    @Namespace private var zoom
    @State private var search = SearchModel()

    var body: some View {
        @Bindable var session = session
        NavigationStack(path: $session.path) {
            TimelineRoot(search: search, zoom: zoom)
                .navigationDestination(for: Route.self) { route in
                    RouteDestination(route: route, zoom: zoom)
                }
        }
        .sheet(item: presentsSheets ? $session.composer : .constant(nil)) { request in
            ComposerView(request: request)
                .zoomTransition(from: ComposerView.transitionID(for: request), in: zoom)
        }
        .sheet(isPresented: presentsSheets ? $session.isInboxPresented : .constant(false)) {
            InboxView()
        }
        .sheet(isPresented: presentsSheets ? $session.isSettingsPresented : .constant(false)) {
            SettingsView()
        }
        .sheet(isPresented: presentsSheets ? $session.isQuickVoiceMemoPresented : .constant(false)) {
            QuickVoiceMemoSheet()
        }
        .environment(\.openURL, OpenURLAction { url in
            handle(url)
        })
    }

    private func handle(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "memos" else { return .systemAction }
        if url.host() == "tag" {
            let tag = url.path().dropFirst().removingPercentEncoding ?? String(url.path().dropFirst())
            session.path.append(.filtered(title: "#\(tag)", tokens: [.tag(tag)]))
        } else {
            session.open(url)
        }
        return .handled
    }
}

/// The timeline itself, with the toolbars and search attached.
private struct TimelineRoot: View {
    @Bindable var search: SearchModel
    let zoom: Namespace.ID

    @Environment(AccountSession.self) private var session
    @State private var feed = OthersFeed()
    @State private var isSearching = false
    @State private var newSpace: String?
    @State private var savedCount = 0

    private var query: MemoQuery {
        let filter = session.quickFilter.flatMap { try? MemoFilter($0.filterClause) }
        return MemoQuery(scope: session.effectiveScope, space: session.selectedSpace, filter: filter)
    }

    private var memos: [Memo] {
        let all = session.memos(query)
        return session.effectiveScope == .everyone ? feed.visible(all, online: session.isOnline) : all
    }

    var body: some View {
        Group {
            if isSearching {
                SearchContent(search: search, zoom: zoom)
            } else {
                timeline
            }
        }
        .background(.paper)
        .navigationTitle("Memos")
        .navigationSubtitle(subtitle)
        // The Space menu grows out of the title. `.inlineLarge` drops the title menu, so the
        // title is inline.
        .toolbarTitleDisplayMode(.inline)
        .toolbarTitleMenu { TitleMenu(newSpace: $newSpace) }
        .toolbar { toolbar }
        .searchable(text: $search.text, tokens: $search.tokens, isPresented: $isSearching, prompt: "Memos, #tags, filters") { token in
            // A tag's “#” already says what it is.
            if case .tag = token {
                Text(token.label)
            } else {
                Label(token.label, systemImage: token.systemImage)
            }
        }
        .textInputAutocapitalization(.never)
        .searchToolbarBehavior(.minimize)
        .searchScopes($search.scope, activation: .onSearchPresentation) {
            if session.showsScopeToggle {
                Text("Mine").tag(MemoQuery.Scope.mine)
                Text("Everyone").tag(MemoQuery.Scope.everyone)
            }
        }
        .onChange(of: isSearching) { _, searching in
            if searching { search.begin(in: session) } else { search.end() }
        }
        .onChange(of: session.pendingSearch, initial: true) { _, pending in
            guard let pending else { return }
            search.text = pending.text
            search.tokens = pending.tokens
            isSearching = true
            session.pendingSearch = nil
        }
        .alert("New Space", isPresented: Binding(get: { newSpace != nil }, set: { if !$0 { newSpace = nil } })) {
            TextField("Title", text: Binding(get: { newSpace ?? "" }, set: { newSpace = $0 }))
            Button("Create") { createSpace() }
            Button("Cancel", role: .cancel) { newSpace = nil }
        } message: {
            Text("Spaces are shared with the people you invite. Invite them on the web.")
        }
        .sensoryFeedback(.success, trigger: savedCount)
    }

    private var subtitle: String {
        var parts = [session.selectedSpaceTitle]
        if session.showsScopeToggle && session.scope == .everyone { parts.append(String(localized: "Everyone")) }
        if let filter = session.quickFilter { parts.append(filter.label) }
        if !session.isOnline { parts.append(String(localized: "Offline")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Timeline

    private var timeline: some View {
        let memos = self.memos
        return List {
            if session.effectiveScope == .everyone, !session.isOnline, let fetched = session.store.state.othersFetchedAt {
                Text("Updated \(fetched.formatted(.relative(presentation: .named)))")
                    .font(.metadata)
                    .foregroundStyle(.ink2)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            ForEach(memos, id: \.name) { memo in
                TimelineRow(memo: memo, zoom: zoom, showsSpace: session.selectedSpace == nil)
                    .id(memo.name)
            }

            if session.effectiveScope == .everyone, feed.hasMore, session.isOnline {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .task(id: memos.count) { await feed.loadMore(using: session.engine, me: session.user) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.memosSpring, value: memos.map(\.name))
        // VoiceOver: a rotor that jumps between the tags on the timeline.
        .accessibilityRotor("Tags") {
            ForEach(memos.filter { !$0.tags.isEmpty }, id: \.name) { memo in
                ForEach(memo.tags, id: \.self) { tag in
                    AccessibilityRotorEntry(Text(verbatim: "#\(tag)"), id: memo.name)
                }
            }
        }
        .overlay {
            if memos.isEmpty && session.store.isLoaded && !(session.effectiveScope == .everyone && feed.isLoading) {
                emptyState
            }
        }
        .refreshable {
            await session.engine.sync(fullCompare: true)
            if session.effectiveScope == .everyone {
                feed.reload()
                await feed.loadMore(using: session.engine, me: session.user)
            }
        }
        .onAppear(perform: resetFeed)
        .onChange(of: session.selectedSpace) { resetFeed() }
        .onChange(of: session.quickFilter) { resetFeed() }
        .onChange(of: session.scope) { resetFeed() }
    }

    private func resetFeed() {
        feed.reset(to: .init(space: session.selectedSpace, filter: session.quickFilter?.filterClause))
    }

    @ViewBuilder
    private var emptyState: some View {
        if let quickFilter = session.quickFilter {
            ContentUnavailableView {
                Label("Nothing here", systemImage: "line.3.horizontal.decrease")
            } description: {
                Text("No memos match \(quickFilter.label) in \(session.selectedSpaceTitle).", comment: "The filter's name, then a Space's name or All Spaces.")
            } actions: {
                Button("Clear Filter") { session.quickFilter = nil }
            }
        } else {
            ContentUnavailableView {
                Label("No memos yet", systemImage: "square.and.pencil")
            } description: {
                session.selectedSpace == nil ? Text("Capture a thought and it lands here.") : Text("Nothing in \(session.selectedSpaceTitle) yet.")
            } actions: {
                Button("Capture a Thought") { session.capture() }
                    .buttonStyle(.glass)
            }
        }
    }

    // MARK: Toolbars

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            FilterMenu()
            Button {
                session.isInboxPresented = true
            } label: {
                Image(systemName: "bell")
            }
            .badge(session.store.profile.unreadNotifications)
            // A toolbar badge doesn't redraw when its count changes on its own.
            .id(session.store.profile.unreadNotifications)
            .accessibilityLabel("Inbox")
            .accessibilityValue(session.store.profile.unreadNotifications > 0 ? Text("\(session.store.profile.unreadNotifications) unread") : Text(verbatim: ""))
        }

        ToolbarItem(placement: .bottomBar) {
            Button {
                session.path.append(.library)
            } label: {
                Image(systemName: "books.vertical")
            }
            .accessibilityLabel("Library")
        }
        ToolbarSpacer(.fixed, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            CaptureField(zoom: zoom)
        }
        ToolbarSpacer(.fixed, placement: .bottomBar)
        DefaultToolbarItem(kind: .search, placement: .bottomBar)
    }

    private func createSpace() {
        guard let title = newSpace?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return }
        newSpace = nil
        Task {
            var request = Memos_Api_CreateSpaceRequest()
            request.space.title = title
            if let space = try? await session.client.call(session.client.spaces.createSpace(request:headers:), request) {
                session.store.profile.spaces.append(space)
                session.selectedSpace = space.name
            }
        }
    }
}

/// One memo on the timeline, with its swipe actions: leading pins, trailing archives.
struct TimelineRow: View {
    let memo: Memo
    let zoom: Namespace.ID
    var showsSpace = true
    var highlights: [String] = []

    @Environment(AccountSession.self) private var session
    @State private var swipeCommits = 0

    private var isMine: Bool { memo.creator == session.user }

    var body: some View {
        Button {
            session.path.append(.memo(memo.name))
        } label: {
            MemoCard(memo: memo, highlights: highlights, showsSpace: showsSpace)
                .matchedTransitionSource(id: memo.name, in: zoom)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 6, leading: Metrics.timelineInset, bottom: 6, trailing: Metrics.timelineInset))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if isMine && memo.isArchived {
                Button {
                    swipeCommits += 1
                    withAnimation(.memosSpring) { session.store.setArchived(memo.name, false) }
                } label: {
                    Label("Restore", systemImage: "tray.and.arrow.up")
                }
                .tint(.memosBlue)
            } else if isMine {
                Button {
                    swipeCommits += 1
                    session.store.setPinned(memo.name, !memo.pinned)
                } label: {
                    Label(memo.pinned ? "Unpin" : "Pin" as LocalizedStringKey, systemImage: memo.pinned ? "pin.slash" : "pin")
                }
                .tint(.memosBlue)
            }
        }
        // Archived memos are the only ones deleted by swipe, and never by a full swipe.
        .swipeActions(edge: .trailing, allowsFullSwipe: !memo.isArchived) {
            if isMine && memo.isArchived {
                Button(role: .destructive) {
                    swipeCommits += 1
                    withAnimation(.memosSpring) { session.store.delete(memo.name) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.danger)
            } else if isMine {
                Button {
                    swipeCommits += 1
                    withAnimation(.memosSpring) { session.store.setArchived(memo.name, true) }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.ink2)
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: swipeCommits)
        .contextMenu { MemoActions(memo: memo) }
        .accessibilityElement(children: .combine)
        .accessibilityActions { MemoActions(memo: memo, forAccessibility: true) }
    }
}

/// The actions on a memo, shared by the context menu, the detail menu and VoiceOver.
struct MemoActions: View {
    let memo: Memo
    var forAccessibility = false
    /// Opens the reaction picker in place; without it, React opens the memo.
    var onReact: (() -> Void)?

    @Environment(AccountSession.self) private var session

    var body: some View {
        let isMine = memo.creator == session.user
        if isMine {
            Button(memo.pinned ? "Unpin" : "Pin" as LocalizedStringKey, systemImage: memo.pinned ? "pin.slash" : "pin") {
                session.store.setPinned(memo.name, !memo.pinned)
            }
            if !forAccessibility {
                Button("Edit", systemImage: "pencil") { session.edit(memo.name) }
            }
            Button(memo.isArchived ? "Restore" : "Archive" as LocalizedStringKey, systemImage: memo.isArchived ? "tray.and.arrow.up" : "archivebox") {
                session.store.setArchived(memo.name, !memo.isArchived)
            }
        }
        Button("React", systemImage: "face.smiling") {
            if let onReact { onReact() } else { session.path.append(.memo(memo.name)) }
        }
        Button("Copy Link", systemImage: "link") {
            UIPasteboard.general.url = session.webURL(for: memo)
        }
        if !forAccessibility {
            Button("Copy Text", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = memo.content
            }
        }
    }
}

/// The Space menu that grows out of the title: Mine / Everyone at the top, then Spaces with
/// how many of your memos each holds.
private struct TitleMenu: View {
    @Binding var newSpace: String?
    @Environment(AccountSession.self) private var session

    var body: some View {
        @Bindable var session = session
        let counts = session.store.ownCounts()
        if session.showsScopeToggle {
            Picker("Show", selection: $session.scope) {
                Label("Mine", systemImage: "person").tag(MemoQuery.Scope.mine)
                Label("Everyone", systemImage: "person.2").tag(MemoQuery.Scope.everyone)
            }
            .pickerStyle(.palette)
        }
        Section {
            spaceButton(nil, title: String(localized: "All Spaces"), monogram: "∗", count: counts[nil] ?? 0)
            ForEach(session.store.profile.spaces, id: \.name) { space in
                spaceButton(space.name, title: space.title, monogram: space.monogram, count: counts[space.name] ?? 0)
            }
        }
        Button("New Space…", systemImage: "plus") { newSpace = "" }
            .disabled(!session.isOnline)
    }

    private func spaceButton(_ name: String?, title: String, monogram: String, count: Int) -> some View {
        Button {
            session.selectedSpace = name
        } label: {
            // A menu shows a second Text in the label as the subtitle.
            Label(title, systemImage: session.selectedSpace == name ? "checkmark" : (name == nil ? "square.stack.3d.up" : "square.stack"))
            Text("\(count) memos")
        }
    }
}

/// The filter button in the title row: quick filters for the timeline, and saved views.
private struct FilterMenu: View {
    @Environment(AccountSession.self) private var session

    var body: some View {
        Menu {
            Section {
                ForEach(SearchToken.commonFilters, id: \.self) { token in
                    Button {
                        session.quickFilter = session.quickFilter == token ? nil : token
                    } label: {
                        Label(token.label, systemImage: session.quickFilter == token ? "checkmark" : token.systemImage)
                    }
                }
            }
            if !session.store.profile.views.isEmpty {
                Section("Saved views") {
                    ForEach(session.store.profile.views, id: \.name) { view in
                        Button {
                            session.path.append(.view(view.name))
                        } label: {
                            Text(verbatim: "\(view.emoji.map { "\($0) " } ?? "")\(view.displayTitle)")
                        }
                    }
                }
            }
            if session.quickFilter != nil {
                Button("Clear Filter", systemImage: "xmark", role: .destructive) { session.quickFilter = nil }
            }
        } label: {
            Image(systemName: session.quickFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter")
    }
}
