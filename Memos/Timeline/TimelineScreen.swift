import MemosCore
import SwiftUI

/// Home. One glass row at the top (the “…” menu for Inbox and Settings, the title with its Space
/// menu, the filter and Library) and one at the bottom (the capture field and Search). Memos pass
/// under both.
struct TimelineScreen: View {
    /// False when an enclosing split view presents the composer, Inbox and Settings itself.
    var presentsSheets = true
    /// The split view's namespace, so cards and buttons here are sources for the sheets it
    /// presents.
    var sharedZoom: Namespace.ID?

    @Environment(AccountSession.self) private var session
    @Namespace private var ownZoom
    @State private var search = SearchModel()

    /// Cards zoom into their detail, and the composer, Inbox and Settings out of what opened them.
    private var zoom: Namespace.ID { sharedZoom ?? ownZoom }

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
                .zoomTransition(from: request.source, in: zoom)
        }
        .sheet(isPresented: presentsSheets ? $session.isInboxPresented : .constant(false)) {
            InboxView()
                .zoomTransition(from: session.accountSheetSource, in: zoom)
        }
        .sheet(isPresented: presentsSheets ? $session.isSettingsPresented : .constant(false)) {
            SettingsView()
                .zoomTransition(from: session.accountSheetSource, in: zoom)
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
    @State private var screenWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { screenWidth = $0 }
        .navigationTitle("Memos")
        .navigationSubtitle(subtitle)
        // The Space menu grows out of the title. `.inlineLarge` drops the title menu, so the
        // title is inline.
        .toolbarTitleDisplayMode(.inline)
        // The on-device library has no Spaces, and nobody else's memos, to choose from.
        .toolbarTitleMenu(if: !session.isOnDevice) { TitleMenu(newSpace: $newSpace) }
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
    }

    private var subtitle: String {
        if session.isOnDevice {
            // Says where the memos are, in place of a Space that can't exist here.
            return ([String(localized: "On This iPhone")] + [session.quickFilter?.label].compactMap(\.self)).joined(separator: " · ")
        }
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
                TimelineRow(memo: memo, zoom: zoom, showsSpace: session.selectedSpace == nil, namesEveryAuthor: session.effectiveScope == .everyone)
                    .id(memo.name)
                    // A memo you just saved settles in from the top of its slot.
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
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
        .refreshable(if: session.engine != nil) {
            await session.engine?.sync(fullCompare: true)
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
                Button("Capture a Thought") { session.capture(from: SheetSource.emptyTimeline) }
                    .buttonStyle(.glass)
                    .matchedTransitionSource(id: SheetSource.emptyTimeline, in: zoom)
            }
        }
    }

    // MARK: Toolbars

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            AccountMenu()
        }
        // Inbox and Settings grow out of the button, and shrink back into it.
        .matchedTransitionSource(id: SheetSource.accountMenu, in: zoom)
        ToolbarItemGroup(placement: .topBarTrailing) {
            FilterMenu()
            Button {
                session.path.append(.library)
            } label: {
                Image(systemName: "books.vertical")
                    .foregroundStyle(.ink)
            }
            .accessibilityLabel("Library")
        }

        ToolbarItem(placement: .bottomBar) {
            CaptureField(idealWidth: screenWidth.map(CaptureField.width(in:)))
        }
        // The field opens into the composer.
        .matchedTransitionSource(id: SheetSource.captureField, in: zoom)
        ToolbarSpacer(.fixed, placement: .bottomBar)
        DefaultToolbarItem(kind: .search, placement: .bottomBar)
    }

    private func createSpace() {
        guard let title = newSpace?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return }
        newSpace = nil
        Task {
            var request = Memos_Api_CreateSpaceRequest()
            request.space.title = title
            guard let client = session.client else { return }
            if let space = try? await client.call(client.spaces.createSpace(request:headers:), request) {
                session.store.profile.spaces.append(space)
                session.selectedSpace = space.name
            }
        }
    }
}

/// One memo on the timeline, with its swipe actions: leading pins, trailing archives or edits.
struct TimelineRow: View {
    let memo: Memo
    let zoom: Namespace.ID
    var showsSpace = true
    var highlights: [String] = []
    /// Names the author on your own memos too, as the Everyone feed does so its cards line up.
    /// Elsewhere a memo without a name is yours.
    var namesEveryAuthor = false

    @Environment(AccountSession.self) private var session
    @State private var swipeCommits = 0

    private var isMine: Bool { memo.creator == session.user }

    var body: some View {
        Button {
            session.path.append(.memo(memo.name, source: memo.name))
        } label: {
            MemoCard(memo: memo, highlights: highlights, showsSpace: showsSpace, showsAuthor: namesEveryAuthor || !isMine)
                // The zoom grows out of the card's own paper and corners, not a bare snapshot.
                .matchedTransitionSource(id: memo.name, in: zoom) { source in
                    source
                        .background(.card)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                }
        }
        // Settles under the finger without dimming the white card grey.
        .buttonStyle(.cardPress)
        // Half the gap above and half below, so neighbouring cards sit one gap apart.
        .listRowInsets(EdgeInsets(top: Metrics.cardGap / 2, leading: Metrics.screenInset, bottom: Metrics.cardGap / 2, trailing: Metrics.screenInset))
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
                    withAnimation(.memosSpring) { session.store.setPinned(memo.name, !memo.pinned) }
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
                // After Archive, so a full swipe still archives.
                Button {
                    // The card opens into the editor.
                    session.edit(memo.name, from: memo.name)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.memosBlue)
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: swipeCommits)
        .contextMenu { MemoActions(memo: memo, editSource: memo.name) }
        .accessibilityElement(children: .combine)
        .accessibilityActions { MemoActions(memo: memo, forAccessibility: true) }
    }
}

/// The actions on a memo, shared by the context menu, the detail menu and VoiceOver.
struct MemoActions: View {
    let memo: Memo
    var forAccessibility = false
    /// What the composer grows out of on Edit: the memo's card, or the menu Edit is in.
    var editSource: String?
    /// Opens the reaction picker in place; without it, React opens the memo.
    var onReact: (() -> Void)?

    @Environment(AccountSession.self) private var session

    var body: some View {
        let isMine = memo.creator == session.user
        if isMine {
            Button(memo.pinned ? "Unpin" : "Pin" as LocalizedStringKey, systemImage: memo.pinned ? "pin.slash" : "pin") {
                withAnimation(.memosSpring) { session.store.setPinned(memo.name, !memo.pinned) }
            }
            if !forAccessibility {
                Button("Edit", systemImage: "pencil") { session.edit(memo.name, from: editSource) }
            }
            Button(memo.isArchived ? "Restore" : "Archive" as LocalizedStringKey, systemImage: memo.isArchived ? "tray.and.arrow.up" : "archivebox") {
                withAnimation(.memosSpring) { session.store.setArchived(memo.name, !memo.isArchived) }
            }
        }
        if !session.isOnDevice {
            Button("React", systemImage: "face.smiling") {
                if let onReact { onReact() } else { session.path.append(.memo(memo.name, source: memo.name)) }
            }
        }
        if let link = session.webURL(for: memo) {
            Button("Copy Link", systemImage: "link") {
                UIPasteboard.general.url = link
            }
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

/// The “…” menu in the title row, opening Inbox and Settings. Inbox is rarely urgent, so unread
/// notifications show as a dot rather than a count.
private struct AccountMenu: View {
    @Environment(AccountSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let unread = session.store.profile.unreadNotifications
        Menu {
            // Notifications come from the server; the on-device library has none.
            if !session.isOnDevice {
                Button {
                    session.accountSheetSource = SheetSource.accountMenu
                    session.isInboxPresented = true
                } label: {
                    Label("Inbox", systemImage: "bell")
                    // A menu shows a second Text in the label as the subtitle.
                    if unread > 0 { Text("\(unread) unread") }
                }
            }
            Button("Settings", systemImage: "gearshape") {
                session.accountSheetSource = SheetSource.accountMenu
                session.isSettingsPresented = true
            }
        } label: {
            // The bar's symbols are Ink: Memos Blue is for tags, links and what's selected.
            Image(systemName: "ellipsis")
                .foregroundStyle(.ink)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        UnreadDot(ringed: true)
                            .offset(x: 5, y: -11)
                            // Pops in when a sync brings something new, rather than appearing, and
                            // fades once read: bounce only on arrival.
                            .transition(.asymmetric(
                                insertion: reduceMotion
                                    ? AnyTransition.opacity.animation(.memosFade)
                                    : AnyTransition.scale(scale: 0.5).combined(with: .opacity).animation(.reactionPop),
                                removal: AnyTransition.opacity.animation(.memosFade)
                            ))
                    }
                }
                .animation(reduceMotion ? .memosFade : .reactionPop, value: unread > 0)
        }
        .accessibilityLabel("Account")
        .accessibilityValue(unread > 0 ? Text("\(unread) unread") : Text(verbatim: ""))
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
                        withAnimation(.memosSpring) { session.quickFilter = session.quickFilter == token ? nil : token }
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
                Button("Clear Filter", systemImage: "xmark", role: .destructive) { withAnimation(.memosSpring) { session.quickFilter = nil } }
            }
        } label: {
            // Ink at rest; Memos Blue once a filter is on, since that's a selection.
            Image(systemName: session.quickFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(session.quickFilter == nil ? Color.ink : Color.memosBlue)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel("Filter")
    }
}
