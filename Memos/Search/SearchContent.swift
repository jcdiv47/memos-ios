import MemosCore
import SwiftUI

/// What shows under the search field: suggestions before you type, results after.
struct SearchContent: View {
    @Bindable var search: SearchModel

    @Environment(AccountSession.self) private var session
    @State private var isSavingView = false
    /// The save sheet grows out of Save as view.
    @Namespace private var saveButton

    var body: some View {
        Group {
            if search.query.isEmpty || (search.typedTagPrefix != nil && search.tokens.allSatisfy { if case .space = $0 { true } else { false } }) {
                SearchSuggestions(search: search)
            } else {
                results
            }
        }
        .scrollDismissesKeyboard(.immediately)
        // A tag or Space turning into a token, or a token removed, ticks under the thumb.
        .sensoryFeedback(.selection, trigger: search.tokens.count)
        // Photos indexed while the search is open can match it too.
        .onChange(of: session.photoSearch.indexedCount) { search.schedulePhotos() }
        // The search field floats over the bottom of the list, and without the software
        // keyboard nothing insets the list for it, so its last rows would sit underneath.
        .contentMargins(.bottom, FloatingBar.height + Spacing.l, for: .scrollContent)
        .sheet(isPresented: $isSavingView) {
            SaveViewSheet(query: search.query)
                .presentationDetents([.height(300)])
                .zoomTransition(from: "search.saveView", in: saveButton)
        }
    }

    private var results: some View {
        let own = search.ownResults(in: session)
        let others = search.otherResults(in: session)
        let highlights = search.query.words
        let count = own.count + others.count + photoOnly(beyond: own).count
        return List {
            Section {
                HStack {
                    Text(countLabel(count))
                        .font(.metadata)
                        .foregroundStyle(.ink2)
                        .contentTransition(.numericText(value: Double(count)))
                        .animation(.memosFade, value: count)
                    Spacer()
                    Button("Save as view", systemImage: "bookmark") { isSavingView = true }
                        .labelStyle(.compact)
                        .font(.action)
                        // One color for the symbol and its words, like any tinted text button,
                        // and greyed with them when it can't save.
                        .foregroundStyle(session.isOnDevice || session.isOnline ? Color.memosBlue : Color.ink3)
                        .disabled(!session.isOnDevice && !session.isOnline)
                        .matchedTransitionSource(id: "search.saveView", in: saveButton)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if own.isEmpty && others.isEmpty && search.photos.isEmpty && !search.isLoadingRemote {
                nothingFound
            }

            if !search.photos.isEmpty {
                Section("Photos") {
                    PhotoMatchStrip(matches: search.photos)
                }
            }

            if !own.isEmpty {
                // An empty header still takes up room in a plain list.
                if session.showsScopeToggle && search.scope == .everyone {
                    Section("Yours") {
                        ForEach(own, id: \.name) { memo in
                            SearchRow(memo: memo, highlights: highlights)
                        }
                    }
                } else {
                    Section {
                        ForEach(own, id: \.name) { memo in
                            SearchRow(memo: memo, highlights: highlights)
                        }
                    }
                }
            }

            if search.scope == .everyone && session.showsScopeToggle {
                Section("From others") {
                    if !session.isOnline && others.isEmpty {
                        Text("Connect to search other people’s memos.")
                            .font(.supporting)
                            .foregroundStyle(.ink2)
                    } else if search.isLoadingRemote && others.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if others.isEmpty && !own.isEmpty {
                        Text("Nothing from others.")
                            .font(.supporting)
                            .foregroundStyle(.ink2)
                    } else {
                        ForEach(others, id: \.name) { memo in
                            SearchRow(memo: memo, highlights: highlights)
                        }
                        if !search.remoteNextPageToken.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                // Keyed on the count, so it asks again after each page lands while still on screen.
                                .task(id: search.remote.count) { search.loadMoreRemote() }
                        }
                    }
                }
                // The status lines sit on paper like the results, not on a white band.
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .paperBackground()
        // Results cross-fade as you type instead of jumping row by row.
        .animation(.memosFade, value: own.map(\.name) + others.map(\.name))
    }

    /// Memos found only by a photo, so the count includes them once.
    private func photoOnly(beyond own: [Memo]) -> Set<String> {
        Set(search.photos.map(\.memo.name)).subtracting(own.map(\.name))
    }

    private func countLabel(_ count: Int) -> String {
        String(localized: "\(count) memos")
    }

    @ViewBuilder
    private var nothingFound: some View {
        let description: String = {
            let what = search.query.words.isEmpty ? search.tokens.filter { if case .space = $0 { false } else { true } }.map(\.label).joined(separator: " ") : search.text
            if case .space(_, let title) = search.query.spaceToken {
                return String(localized: "No memos match ‘\(what)’ in \(title).", comment: "Search found nothing: what was searched for, then the Space searched in.")
            }
            return String(localized: "No memos match ‘\(what)’.", comment: "Search found nothing; what was searched for.")
        }()
        VStack(spacing: Spacing.l) {
            Text(description)
                .font(.supporting)
                .multilineTextAlignment(.center)
                .foregroundStyle(.ink2)
            if search.query.spaceToken != nil {
                Button("Search all Spaces") {
                    search.tokens = search.query.removingSpace().tokens
                }
                .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// Photos that look like what you typed, best first, in a row you scroll sideways. A tap opens
/// the memo the photo is in.
private struct PhotoMatchStrip: View {
    let matches: [PhotoSearchModel.Match]

    @Environment(AccountSession.self) private var session

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: Spacing.s) {
                ForEach(matches) { match in
                    Button {
                        session.path.append(.memo(match.memo.name))
                    } label: {
                        AttachmentImage(attachment: match.attachment)
                            .frame(width: 104, height: 104)
                            // A photo in a memo your tags blur stays blurred here too, inside its
                            // own frame rather than bleeding into the next one.
                            .blur(radius: session.isHidden(match.memo) ? 16 : 0, opaque: true)
                            .clipShape(.rect(cornerRadius: Radius.tight))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(session.redactedTitle(of: match.memo))
                    .accessibilityHint("Opens the memo with this photo")
                }
            }
            .padding(.horizontal, Metrics.screenInset)
        }
        .scrollIndicators(.hidden)
        .listRowInsets(EdgeInsets(top: Spacing.xs, leading: 0, bottom: Spacing.xs, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// A two-line result with the matches highlighted.
private struct SearchRow: View {
    let memo: Memo
    let highlights: [String]

    @Environment(AccountSession.self) private var session

    var body: some View {
        Button {
            session.path.append(.memo(memo.name))
        } label: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                let hidden = session.isHidden(memo)
                Text(MarkdownCache.inline(excerpt, highlights: highlights))
                    .font(.supporting)
                    .foregroundStyle(.ink)
                    .lineLimit(2)
                    // Blurred as on its card until you show it there; the memo opens as usual.
                    .blur(radius: hidden ? 6 : 0)
                    .accessibilityRepresentation {
                        if hidden {
                            Text("Sensitive content")
                        } else {
                            Text(MarkdownCache.inline(excerpt, highlights: highlights))
                        }
                    }
                Text(metadata)
                    .font(.metadata)
                    .foregroundStyle(.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Spacing.xs)
            .contentShape(.rect)
        }
        .buttonStyle(.cardPress)
        .listRowBackground(Color.clear)
    }

    /// Starts the excerpt near the first match, so it's visible within two lines.
    private var excerpt: String {
        let flat = MarkdownCache.plainText(of: memo)
        guard let word = highlights.first, let range = flat.range(of: word, options: .caseInsensitive) else { return flat }
        var start = flat.index(range.lowerBound, offsetBy: -40, limitedBy: flat.startIndex) ?? flat.startIndex
        guard start != flat.startIndex else { return flat }
        // Begin on a whole word, “…the collection”, never “…ets #quote”.
        if let space = flat[start..<range.lowerBound].firstIndex(where: \.isWhitespace) {
            start = flat.index(after: space)
        }
        return "…" + flat[start...]
    }

    private var metadata: String {
        var parts: [String] = []
        if memo.creator != session.user { parts.append(session.people.name(for: memo.creator)) }
        parts.append(memo.createdAt.formatted(.dateTime.month(.abbreviated).day()))
        if let title = session.space(named: memo.spaceName)?.title { parts.append(title) }
        return parts.joined(separator: " · ")
    }
}

/// Before you type: recent searches, your most-used tags, and common filters.
private struct SearchSuggestions: View {
    @Bindable var search: SearchModel
    @Environment(AccountSession.self) private var session

    var body: some View {
        let tags = session.store.tagCounts()
        let prefix = search.typedTagPrefix
        List {
            if prefix == nil, !search.recents.isEmpty {
                Section {
                    ForEach(search.recents, id: \.self) { recent in
                        Button {
                            search.applyRecent(recent)
                        } label: {
                            Label(recent, systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.ink)
                        }
                    }
                    .cardRows()
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Button("Clear") { search.clearRecents() }
                            .font(.action)
                    }
                }
            }

            let matchingTags = tags.filter { entry in prefix.map { $0.isEmpty || entry.tag.localizedCaseInsensitiveContains($0) } ?? true }
            if !matchingTags.isEmpty {
                Section("Tags") {
                    ForEach(matchingTags.prefix(prefix == nil ? 6 : 20), id: \.tag) { tag in
                        Button {
                            search.addToken(.tag(tag.tag))
                        } label: {
                            HStack {
                                Text(verbatim: "#\(tag.tag)").foregroundStyle(.memosBlue)
                                Spacer()
                                Text(tag.count, format: .number).foregroundStyle(.ink2).monospacedDigit()
                            }
                        }
                    }
                    .cardRows()
                }
            }

            if prefix == nil {
                Section("Filters") {
                    Group {
                        ForEach(SearchToken.commonFilters, id: \.self) { token in
                            Button {
                                search.addToken(token)
                            } label: {
                                Label(token.label, systemImage: token.systemImage)
                                    .foregroundStyle(.ink)
                            }
                        }
                        Menu {
                            ForEach(MemoVisibility.choices, id: \.self) { visibility in
                                Button(visibility.label, systemImage: visibility.systemImage) { search.addToken(.visibility(visibility)) }
                            }
                        } label: {
                            Label("Visibility", systemImage: "eye")
                                .foregroundStyle(.ink)
                        }
                        Menu {
                            Button("Today") { search.addToken(.date(.today)) }
                            Button("This week") { search.addToken(.date(.thisWeek)) }
                            Button("This month") { search.addToken(.date(.thisMonth)) }
                        } label: {
                            Label("Date", systemImage: "calendar")
                                .foregroundStyle(.ink)
                        }
                    }
                    .cardRows()
                }
            }
        }
        .listStyle(.insetGrouped)
        .paperBackground()
    }
}

/// “Save as view”: a name and an emoji, saved as a MemoView on the server, so it also appears
/// on the web.
struct SaveViewSheet: View {
    let query: SearchQuery

    @Environment(AccountSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var emoji = "🔖"
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField(text: $emoji, prompt: Text(verbatim: "🔖")) { Text("Emoji") }
                            .frame(width: 44)
                            .multilineTextAlignment(.center)
                            .onChange(of: emoji) { _, value in
                                if let last = value.last, value.count > 1 { emoji = String(last) }
                            }
                        TextField("Name", text: $title)
                    }
                    .cardRows()
                } footer: {
                    Text(query.filter() ?? "")
                        .font(.memoCode)
                    if let error { Text(error).foregroundStyle(.danger) }
                }
            }
            .paperBackground()
            .navigationTitle("Save as View")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .buttonStyle(.glassProminent)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
    }

    private func save() async {
        guard let filter = query.filter() else { return }
        isSaving = true
        defer { isSaving = false }
        var request = Memos_Api_CreateMemoViewRequest()
        request.parent = session.user
        request.memoView.title = title.trimmingCharacters(in: .whitespaces)
        request.memoView.filter = filter
        if !emoji.isEmpty { request.memoView.icon.emoji = emoji }
        guard let client = session.client else {
            // The on-device library keeps its views itself, with the rest of its profile.
            var view = request.memoView
            view.name = "\(session.user)/memoViews/\(ResourceID.generate())"
            session.store.profile.views.append(view)
            dismiss()
            return
        }
        do {
            let view = try await client.call(client.users.createMemoView(request:headers:), request)
            session.store.profile.views.append(view)
            dismiss()
        } catch {
            self.error = error.description
        }
    }
}
