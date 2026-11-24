import MemosCore
import SwiftUI

/// One memo's detail view. Reactions, comments and sharing sit in a floating glass bar; anything
/// that reaches another person needs a connection.
struct MemoDetailView: View {
    let name: String
    /// The presenter's namespace: the composer, the share link and the comment editor grow out of
    /// what opened them.
    let zoom: Namespace.ID

    @Environment(AccountSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var comments: [Memo] = []
    @State private var commentsLoaded = false
    @State private var missing = false
    @State private var linkPreview: Memos_Api_LinkMetadata?
    @State private var confirmDelete = false
    @State private var shareURL: URL?
    @State private var notice: String?
    @State private var reactionPickerOpen = false
    @State private var editingComment: EditableComment?
    @State private var commentToDelete: Memo?
    /// A reaction shown before the server confirms it, so a tap lands at once. Cleared when the
    /// refreshed memo arrives, or on failure, which puts the chips back as they were.
    @State private var pendingReaction: PendingReaction?
    @State private var chipTaps = 0

    private var memo: Memo? { session.store.memo(named: name).map(withPendingReaction) }

    var body: some View {
        Group {
            if let memo {
                content(memo)
            } else if missing {
                ContentUnavailableView("Memo not found", systemImage: "questionmark.square.dashed", description: Text("It was deleted, or you can no longer read it."))
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.paper)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: name) { await load() }
        // Keyed on the link, so an edit that adds, changes or removes it updates the card.
        .task(id: previewURL) { await loadLinkPreview(previewURL) }
    }

    private var previewURL: String? { memo.flatMap { Self.firstLink(in: $0.content) } }

    @ViewBuilder
    private func content(_ memo: Memo) -> some View {
        let isMine = memo.creator == session.user
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                MemoHeader(memo: memo)

                if session.store.conflictCounterpart(of: memo.name) != nil {
                    ConflictBanner(memo: memo)
                }

                SensitiveContent(memo: memo) {
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        if let audio = memo.audioAttachment {
                            AudioAttachmentView(attachment: audio)
                        }

                        MemoContentView(
                            content: memo.content,
                            onToggleTask: isMine ? { line in session.store.toggleTask(memo.name, line: line) } : nil,
                            titleFont: .largeTitleSerif
                        )
                        .textSelection(.enabled)

                        if memo.attachments.contains(where: { !$0.isAudio }) {
                            AttachmentGallery(attachments: memo.attachments.filter { !$0.isAudio }, maxImages: 12)
                        }

                        if let location = memo.locationIfSet {
                            Label(location.placeholder.isEmpty ? String(localized: "Location") : location.placeholder, systemImage: "mappin.and.ellipse")
                                .labelStyle(.compact)
                                .font(.metadata)
                                .foregroundStyle(.ink2)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(location.placeholder.isEmpty ? Text("Location") : Text("Location, \(location.placeholder)"))
                        }

                        MemoLinks(memo: memo, showsDirection: true)

                        if let linkPreview {
                            LinkPreviewCard(metadata: linkPreview)
                        }
                    }
                }
                .id(memo.name)

                if !memo.reactions.isEmpty {
                    ReactionSummary(memo: memo) { emoji in
                        chipTaps += 1
                        Task { await toggleReaction(emoji, on: memo) }
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: chipTaps)
                    // Bounces in because you put it there; leaves quieter than it came.
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity).animation(.reactionPop),
                        removal: .opacity.animation(.memosFade)
                    ))
                }

                // Comments live on the server; the on-device library has none.
                if !session.isOnDevice {
                    commentsSection
                }
            }
            .padding(Metrics.screenInset)
            .padding(.bottom, Metrics.floatingBarClearance)
            .readableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            DetailBar(memo: memo, pickerOpen: $reactionPickerOpen, onReact: { emoji in await toggleReaction(emoji, on: memo) }, onComment: { text in await comment(text, on: memo) })
                .padding(.horizontal, Metrics.screenInset)
                .padding(.bottom, Spacing.m)
                .readableWidth()
        }
        .overlay(alignment: .top) {
            if let notice {
                Toast(message: notice)
                    .padding(.top, Spacing.m)
                    .transition(toastTransition)
                    // Each new message gets its full time on screen.
                    .task(id: notice) {
                        // Cancelled by the next message, which mustn't be cleared early.
                        guard (try? await Task.sleep(for: .seconds(2.5))) != nil else { return }
                        withAnimation(.memosFade) { self.notice = nil }
                    }
            }
        }
        // Every message here is a refusal, mostly being offline: a warning, felt once per message.
        .sensoryFeedback(.warning, trigger: notice) { _, new in new != nil }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    MemoActions(memo: memo, editSource: SheetSource.detailMenu, onReact: { withAnimation(.memosSpring) { reactionPickerOpen = true } })
                    if !session.isOnDevice {
                        Button("Create Share Link", systemImage: "link.badge.plus") {
                            Task { await createShareLink(memo) }
                        }
                        .disabled(!session.isOnline)
                    }
                    if isMine {
                        if !session.isOnDevice {
                            Menu("Move to", systemImage: "square.stack") {
                                Button("No Space") { session.store.setAudience(memo.name, visibility: memo.visibility, space: nil) }
                                ForEach(session.store.profile.spaces, id: \.name) { space in
                                    Button(space.title) {
                                        session.store.setAudience(memo.name, visibility: VisibilityRules.afterAddingSpace(memo.visibility), space: space.name)
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                } label: {
                    // Ink, like the back chevron beside it: Memos Blue is for what you chose.
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.ink)
                }
                .accessibilityLabel("More")
                // Anchored to the menu Delete is in, so the question points at what asked it.
                .confirmationDialog("Delete this memo?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        session.store.delete(memo.name)
                        dismiss()
                    }
                } message: {
                    if session.isOnDevice {
                        Text("It’s removed from this iPhone, along with its attachments.")
                    } else {
                        Text("It’s removed everywhere, along with its comments.")
                    }
                }
            }
            .matchedTransitionSource(id: SheetSource.detailMenu, in: zoom)
        }
        .sheet(item: Binding(get: { shareURL.map(IdentifiedURL.init) }, set: { shareURL = $0?.url })) { item in
            ShareLinkSheet(url: item.url)
                .presentationDetents([.height(220)])
                .zoomTransition(from: SheetSource.detailMenu, in: zoom)
        }
        .sheet(item: $editingComment) { item in
            CommentEditor(original: item.memo.content) { text in
                await editComment(item.memo, to: text)
            }
            // Medium leaves the top of the memo, where errors appear, in view.
            .presentationDetents([.medium, .large])
            // Grows out of the comment being edited.
            .zoomTransition(from: CommentsSection.sourceID(item.memo), in: zoom)
        }
    }

    private var commentsSection: some View {
        CommentsSection(
            comments: comments,
            loaded: commentsLoaded,
            online: session.isOnline,
            zoom: zoom,
            toDelete: $commentToDelete,
            onEdit: { editingComment = EditableComment(memo: $0) },
            onConfirmDelete: { comment in Task { await deleteComment(comment) } }
        )
    }

    // MARK: Loading

    private func load() async {
        if let engine = session.engine, memo == nil || session.isOnline {
            do {
                try await engine.refresh(name)
            } catch {
                if error.code == .notFound || error.code == .permissionDenied { missing = true }
                if memo == nil && !error.isConnectivity { missing = true }
            }
        } else if memo == nil {
            // Nowhere else to look: the on-device library holds every memo it has.
            missing = true
        }
        await loadComments()
    }

    private func loadComments() async {
        guard session.isOnline, let client = session.client else {
            commentsLoaded = true
            return
        }
        var request = Memos_Api_ListMemoCommentsRequest()
        request.parent = name
        request.pageSize = 200
        request.orderBy = "create_time asc"
        if let response = try? await client.call(client.memos.listMemoComments(request:headers:), request) {
            // Oldest first, like a conversation. The server ignores order_by here.
            withAnimation(.memosSpring) { comments = response.comments.sorted { $0.createTime.date < $1.createTime.date } }
        }
        commentsLoaded = true
    }

    private func loadLinkPreview(_ url: String?) async {
        guard let url else {
            withAnimation(.memosSpring) { linkPreview = nil }
            return
        }
        if linkPreview?.url != url { linkPreview = nil }
        if let cached = session.linkPreviews[url] {
            linkPreview = cached
            return
        }
        guard session.isOnline, let client = session.client else { return }
        var request = Memos_Api_GetLinkMetadataRequest()
        request.url = url
        if let metadata = try? await client.call(client.memos.getLinkMetadata(request:headers:), request),
           !metadata.title.isEmpty {
            session.linkPreviews[url] = metadata
            withAnimation(.memosSpring) { linkPreview = metadata }
        }
    }

    static func firstLink(in content: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let match = detector.firstMatch(in: content, range: NSRange(content.startIndex..., in: content))
        return match?.url.flatMap { $0.scheme?.hasPrefix("http") == true ? $0.absoluteString : nil }
    }

    // MARK: Actions

    private func withPendingReaction(_ memo: Memo) -> Memo {
        guard let pendingReaction else { return memo }
        var memo = memo
        let isPending = { (reaction: Reaction) in reaction.reactionType == pendingReaction.emoji && reaction.creator == session.user }
        if pendingReaction.adding {
            if !memo.reactions.contains(where: isPending) {
                var reaction = Reaction()
                reaction.reactionType = pendingReaction.emoji
                reaction.creator = session.user
                memo.reactions.append(reaction)
            }
        } else {
            memo.reactions.removeAll(where: isPending)
        }
        return memo
    }

    private func toggleReaction(_ emoji: String, on memo: Memo) async {
        guard session.isOnline, let client = session.client else {
            show("Connect to react.")
            return
        }
        // One at a time: removing needs the server's name for the reaction.
        guard pendingReaction == nil, let stored = session.store.memo(named: memo.name) else { return }
        let existing = stored.reactions.first(where: { $0.reactionType == emoji && $0.creator == session.user })
        withAnimation(reactionAnimation) { pendingReaction = PendingReaction(emoji: emoji, adding: existing == nil) }
        defer { withAnimation(reactionAnimation) { pendingReaction = nil } }
        do {
            if let existing {
                var request = Memos_Api_DeleteMemoReactionRequest()
                request.name = existing.name
                _ = try await client.call(client.memos.deleteMemoReaction(request:headers:), request)
            } else {
                var request = Memos_Api_UpsertMemoReactionRequest()
                request.parent = memo.name
                request.reaction.reactionType = emoji
                _ = try await client.call(client.memos.upsertMemoReaction(request:headers:), request)
            }
            _ = try? await session.engine?.refresh(memo.name)
        } catch {
            show(error.isConnectivity ? "Connect to react." : "Couldn’t react: \(error.description)" as LocalizedStringResource)
        }
    }

    /// Comments send only when online, so nobody receives one hours after you thought you sent it.
    private func comment(_ text: String, on memo: Memo) async -> Bool {
        guard session.isOnline, let client = session.client else {
            show("Connect to comment.")
            return false
        }
        var request = Memos_Api_CreateMemoCommentRequest()
        request.parent = memo.name
        request.comment.content = text
        request.comment.visibility = memo.visibility
        // A Space comment needs the Space too, so the same members can read it.
        if memo.visibility == .space, let space = memo.spaceName {
            request.comment.space = space
        }
        request.comment.state = .normal
        do {
            let created = try await client.call(client.memos.createMemoComment(request:headers:), request)
            withAnimation(.memosSpring) { comments.append(created) }
            return true
        } catch {
            show(error.isConnectivity ? "Connect to comment." : "Couldn’t comment: \(error.description)" as LocalizedStringResource)
            return false
        }
    }

    /// Like adding a comment, editing and deleting one happen only online, so what others read
    /// never lags behind what you see.
    private func editComment(_ comment: Memo, to text: String) async -> Bool {
        guard session.isOnline, let client = session.client else {
            show("Connect to edit comments.")
            return false
        }
        var request = Memos_Api_UpdateMemoRequest()
        request.memo.name = comment.name
        request.memo.content = text
        // The server moves `update_time` only when the mask asks, as the sync engine does for memos.
        request.updateMask.paths = ["content", "update_time"]
        do {
            let updated = try await client.call(client.memos.updateMemo(request:headers:), request)
            withAnimation(.memosSpring) {
                if let index = comments.firstIndex(where: { $0.name == comment.name }) { comments[index] = updated }
            }
            await refreshStoredCopy(of: comment.name)
            return true
        } catch {
            show(error.isConnectivity ? "Connect to edit comments." : "Couldn’t edit the comment: \(error.description)" as LocalizedStringResource)
            return false
        }
    }

    private func deleteComment(_ comment: Memo) async {
        guard session.isOnline, let client = session.client else {
            show("Connect to delete comments.")
            return
        }
        var request = Memos_Api_DeleteMemoRequest()
        request.name = comment.name
        do {
            _ = try await client.call(client.memos.deleteMemo(request:headers:), request)
        } catch where error.code == .notFound {
            // Already gone.
        } catch {
            show(error.isConnectivity ? "Connect to delete comments." : "Couldn’t delete the comment: \(error.description)" as LocalizedStringResource)
            return
        }
        withAnimation(.memosSpring) { comments.removeAll { $0.name == comment.name } }
        await refreshStoredCopy(of: comment.name)
    }

    /// A comment opened on its own (from the inbox) has a local copy; refetching updates it, or
    /// removes it once deleted.
    private func refreshStoredCopy(of name: String) async {
        guard session.store.memo(named: name) != nil else { return }
        _ = try? await session.engine?.refresh(name)
    }

    private func createShareLink(_ memo: Memo) async {
        guard let client = session.client else { return }
        var request = Memos_Api_CreateMemoShareRequest()
        request.parent = memo.name
        do {
            let share = try await client.call(client.memos.createMemoShare(request:headers:), request)
            let token = ResourceName.lastSegment(share.name)
            shareURL = client.serverURL.appending(path: "memos/shares/\(token)")
        } catch {
            if error.isConnectivity {
                show("Connect to create a share link.")
            } else {
                show(verbatim: error.description)
            }
        }
    }

    /// Drops a few points into place and settles; leaves by fading up a little, shorter than it
    /// came. Reduce Motion only fades.
    private var toastTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .offset(y: -10).combined(with: .scale(scale: 0.96, anchor: .top)).combined(with: .opacity),
            removal: .offset(y: -6).combined(with: .opacity)
        )
    }

    /// The chosen emoji pops in; Reduce Motion keeps the change without the bounce.
    private var reactionAnimation: Animation {
        reduceMotion ? .memosFade : .reactionPop
    }

    private func show(_ message: LocalizedStringResource) {
        show(verbatim: String(localized: message))
    }

    /// For text that is already in the reader's language, such as a server's error message.
    private func show(verbatim message: String) {
        withAnimation(.memosSpring) { notice = message }
    }
}

private struct PendingReaction: Equatable {
    let emoji: String
    let adding: Bool
}

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct EditableComment: Identifiable {
    let memo: Memo
    var id: String { memo.name }
}

/// “Edited on another device. Your version was saved separately.”, with a way to the other half.
private struct ConflictBanner: View {
    let memo: Memo
    @Environment(AccountSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Label("Edited on another device. Your version was saved separately.", systemImage: "arrow.triangle.branch")
                .font(.supporting)
                .foregroundStyle(.ink)
            HStack {
                if let other = session.store.conflictCounterpart(of: memo.name) {
                    Button("Open the other version") { session.path.append(.memo(other)) }
                }
                Spacer()
                Button("Dismiss") { session.store.dismissConflict(memo.name) }
            }
            .font(.action)
        }
        .wellBackground()
    }
}

private struct LinkPreviewCard: View {
    let metadata: Memos_Api_LinkMetadata
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: metadata.url) { openURL(url) }
        } label: {
            HStack(spacing: Spacing.l) {
                SiteTile(imageURL: URL(string: metadata.image), host: host)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(metadata.title)
                        .font(.emphasis)
                        .foregroundStyle(.ink)
                        .lineLimit(2)
                    Text(host)
                        .font(.metadata)
                        .foregroundStyle(.ink2)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.rowSymbol)
                    .foregroundStyle(.ink2)
                    .accessibilityHidden(true)
            }
            .padding(Spacing.l)
            .cardBackground()
        }
        .buttonStyle(.cardPress)
    }

    private var host: String {
        let host = URL(string: metadata.url)?.host() ?? metadata.url
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// The site's picture beside a link preview, on a well tile like an ``IconTile``; the first
/// letter of the site's address while it loads, or if the site has none.
private struct SiteTile: View {
    let imageURL: URL?
    let host: String

    @ScaledMetric(relativeTo: .subheadline) private var scale = SymbolScale.base

    var body: some View {
        let side = Metrics.scaled(Metrics.iconTile, by: scale)
        AsyncImage(url: imageURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Text(host.first.map { String($0).uppercased() } ?? "")
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(.ink2)
            }
        }
        .frame(width: side, height: side)
        .background(.well)
        .clipShape(.rect(cornerRadius: Radius.inner))
        .accessibilityHidden(true)
    }
}

private struct CommentsSection: View {
    let comments: [Memo]
    let loaded: Bool
    let online: Bool
    let zoom: Namespace.ID
    /// The comment whose Delete was chosen, awaiting the answer.
    @Binding var toDelete: Memo?
    var onEdit: (Memo) -> Void
    var onConfirmDelete: (Memo) -> Void
    @Environment(AccountSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A comment you post rises out of the bar you typed it in; one you delete just fades.
    private var arrival: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .offset(y: Spacing.xxl).combined(with: .opacity), removal: .opacity)
    }

    /// A comment is a memo, so its name gets a prefix to keep it apart from a memo card's.
    static func sourceID(_ comment: Memo) -> String { "comment.\(comment.name)" }

    /// Hairlines between comments start under the text, past the avatar.
    private static var dividerInset: CGFloat { AvatarSize.small + Spacing.m }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            if !comments.isEmpty {
                SectionHeader(title: Text("\(comments.count) comments")) { EmptyView() }
                    .contentTransition(.numericText(value: Double(comments.count)))
                CardList(dividerInset: Self.dividerInset) {
                    ForEach(comments, id: \.name) { comment in
                        row(comment)
                    }
                }
            }
            if loaded && !online && comments.isEmpty {
                Text("Comments load when you’re online.")
                    .font(.metadata)
                    .foregroundStyle(.ink2)
            }
        }
    }

    private func row(_ comment: Memo) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            UserAvatar(user: comment.creator, size: AvatarSize.small)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(session.people.name(for: comment.creator))
                        .font(.emphasis)
                        .foregroundStyle(.ink)
                    Text(MemoDate.short(comment.createdAt))
                        .font(.metadata)
                        .foregroundStyle(.ink2)
                    Spacer(minLength: 0)
                    RevealToggle(memo: comment)
                }
                SensitiveContent(memo: comment) {
                    MemoContentView(content: comment.content, showsTitle: false)
                }
            }
        }
        .padding(.vertical, Metrics.rowPadding)
        .accessibilityElement(children: .combine)
        .contentShape(.contextMenuPreview, .rect(cornerRadius: Radius.inner))
        .matchedTransitionSource(id: Self.sourceID(comment), in: zoom)
        .transition(arrival)
        .contextMenu { actions(for: comment) }
        .accessibilityActions { actions(for: comment) }
        // Anchored to the comment it's about, not the whole list.
        .confirmationDialog(
            "Delete this comment?",
            isPresented: Binding(get: { toDelete?.name == comment.name }, set: { if !$0 { toDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { onConfirmDelete(comment) }
        } message: {
            Text("It’s removed for everyone who can read this memo.")
        }
    }

    /// Only for your own comments: the server lets nobody else change them, admins aside.
    @ViewBuilder
    private func actions(for comment: Memo) -> some View {
        if comment.creator == session.user {
            Button("Edit", systemImage: "pencil") { onEdit(comment) }
                .disabled(!online)
            Button("Delete", systemImage: "trash", role: .destructive) { toDelete = comment }
                .disabled(!online)
        }
    }
}

/// Edits one of your comments. Comments are short, so a plain text view does rather than the
/// composer.
private struct CommentEditor: View {
    let original: String
    var onSave: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var saving = false
    @FocusState private var focused: Bool

    init(original: String, onSave: @escaping (String) async -> Bool) {
        self.original = original
        self.onSave = onSave
        _draft = State(initialValue: original)
    }

    private var text: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            TextEditor(text: $draft)
                .font(.memoBody)
                .foregroundStyle(.ink)
                .focused($focused)
                .scrollContentBackground(.hidden)
                // TextEditor insets its text by 5 points; this lines it up with the screen margin.
                .padding(.horizontal, Metrics.screenInset - 5)
                .background(.paper)
                .navigationTitle("Edit Comment")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .buttonStyle(.glassProminent)
                            .disabled(text.isEmpty || text == original.trimmingCharacters(in: .whitespacesAndNewlines) || saving)
                    }
                }
        }
        .interactiveDismissDisabled(draft != original || saving)
        .onAppear { focused = true }
    }

    private func save() {
        guard !text.isEmpty, !saving else { return }
        saving = true
        Task {
            if await onSave(text) { dismiss() }
            saving = false
        }
    }
}

/// The floating bar: react, comment and share. The reaction picker grows out of the react
/// button, which it replaces.
private struct DetailBar: View {
    let memo: Memo
    @Binding var pickerOpen: Bool
    var onReact: (String) async -> Void
    var onComment: (String) async -> Bool

    @Environment(AccountSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass
    @State private var draft = ""
    @State private var sending = false
    @State private var reacted = 0
    @FocusState private var commentFocused: Bool

    var body: some View {
        GlassEffectContainer(spacing: Spacing.l) {
            HStack(spacing: Spacing.l) {
                if pickerOpen {
                    HStack(spacing: Spacing.xs) {
                        // A server can offer more reactions than fit; they scroll instead of
                        // widening the bar, and with it the whole page, past the screen edge.
                        ViewThatFits(in: .horizontal) {
                            reactionChoices
                            FadingHorizontalScroll { reactionChoices }
                        }
                        Button {
                            withAnimation(pickerAnimation) { pickerOpen = false }
                        } label: {
                            Image(systemName: "xmark").frame(width: 32, height: Metrics.minTapTarget)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close reactions")
                    }
                    .padding(.horizontal, Spacing.m)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("react", in: glass)
                } else if session.isOnDevice {
                    // Nobody to react or comment: sharing the text is all that's left here.
                    Spacer(minLength: 0)
                    shareButton
                } else {
                    Button {
                        withAnimation(pickerAnimation) { pickerOpen = true }
                    } label: {
                        Image(systemName: "face.smiling")
                            .font(.barSymbol)
                            .frame(width: FloatingBar.height, height: FloatingBar.height)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("react", in: glass)
                    .accessibilityLabel("React")

                    HStack {
                        TextField("Add a comment", text: $draft, axis: .vertical)
                            .lineLimit(1...4)
                            .focused($commentFocused)
                            .submitLabel(.send)
                            .onSubmit { send() }
                        if !draft.isEmpty {
                            Button {
                                send()
                            } label: {
                                Group {
                                    if sending {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "arrow.up.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(.memosBlue)
                                    }
                                }
                                .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.glyphPress)
                            .disabled(sending)
                            .accessibilityLabel("Send comment")
                            // Grows in under the thumb as you start typing, instead of popping.
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .animation(.memosFade, value: draft.isEmpty)
                    .animation(.memosFade, value: sending)
                    .padding(.horizontal, Spacing.xl)
                    .frame(minHeight: FloatingBar.height)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("comment", in: glass)

                    shareButton
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: reacted)
    }

    /// Shares the memo's web address, or in the on-device library, where it has none, its text.
    private var shareButton: some View {
        Group {
            if let link = session.webURL(for: memo) {
                ShareLink(item: link, subject: Text(memo.displayTitle), message: Text(memo.previewText)) { shareSymbol }
            } else {
                ShareLink(item: memo.content, subject: Text(memo.displayTitle)) { shareSymbol }
            }
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("share", in: glass)
        .accessibilityLabel("Share")
    }

    private var shareSymbol: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.barSymbol)
            .frame(width: FloatingBar.height, height: FloatingBar.height)
    }

    private var reactionChoices: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(session.store.profile.reactionChoices, id: \.self) { emoji in
                let isMine = memo.reactions.contains { $0.reactionType == emoji && $0.creator == session.user }
                Button {
                    reacted += 1
                    withAnimation(pickerAnimation) { pickerOpen = false }
                    Task { await onReact(emoji) }
                } label: {
                    Text(emoji)
                        .font(.title2)
                        .frame(width: 40, height: Metrics.minTapTarget)
                        // Opaque inside the glass: the ones you've already used.
                        .background {
                            if isMine {
                                Circle().fill(Color.accentWash).frame(width: 38, height: 38)
                            }
                        }
                }
                .buttonStyle(.glyphPress)
                .accessibilityLabel("React with \(emoji)")
                .accessibilityAddTraits(isMine ? .isSelected : [])
            }
        }
    }

    /// Settles with a small bounce on the emoji you pick; Reduce Motion keeps the morph without it.
    private var pickerAnimation: Animation {
        reduceMotion ? .spring(response: 0.3, dampingFraction: 1) : .reactionPop
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task {
            if await onComment(text) {
                draft = ""
                commentFocused = false
            }
            sending = false
        }
    }
}

/// A row that scrolls sideways and fades whichever edge has more beyond it, so an emoji cut off
/// at the edge reads as more to scroll to rather than as clipped.
private struct FadingHorizontalScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var fadesLeading = false
    @State private var fadesTrailing = true

    private static var fade: CGFloat { Spacing.xxl }

    var body: some View {
        ScrollView(.horizontal) { content }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: [Bool].self) { geometry in
                let offset = geometry.contentOffset.x + geometry.contentInsets.leading
                let room = geometry.contentSize.width - geometry.containerSize.width
                return [offset > 1, offset < room - 1]
            } action: { _, edges in
                withAnimation(.memosFade) {
                    fadesLeading = edges[0]
                    fadesTrailing = edges[1]
                }
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(fadesLeading ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.fade)
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(fadesTrailing ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.fade)
                }
            }
    }
}

private struct ShareLinkSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Text("Anyone with this link can read the memo.")
                .font(.supporting)
                .foregroundStyle(.ink2)
            Text(url.absoluteString)
                .font(.memoCode)
                .foregroundStyle(.ink)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack {
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.url = url
                    dismiss()
                }
                .buttonStyle(.glass)
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(Spacing.xxl)
    }
}
