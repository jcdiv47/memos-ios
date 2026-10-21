import MemosCore
import SwiftUI

/// One memo, opened from its card with a zoom. Reactions, comments and sharing sit in a
/// floating glass bar; anything that reaches another person needs a connection.
struct MemoDetailView: View {
    let name: String

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

    private var memo: Memo? { session.store.memo(named: name) }

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
    }

    @ViewBuilder
    private func content(_ memo: Memo) -> some View {
        let isMine = memo.creator == session.user
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MemoHeader(memo: memo)

                if session.store.conflictCounterpart(of: memo.name) != nil {
                    ConflictBanner(memo: memo)
                }

                SensitiveContent(memo: memo) {
                    VStack(alignment: .leading, spacing: 14) {
                        if let audio = memo.audioAttachment {
                            AudioAttachmentView(attachment: audio)
                        }

                        MemoContentView(
                            content: memo.content,
                            onToggleTask: isMine ? { line in session.store.toggleTask(memo.name, line: line) } : nil
                        )
                        .textSelection(.enabled)

                        if memo.attachments.contains(where: { !$0.isAudio }) {
                            AttachmentGallery(attachments: memo.attachments.filter { !$0.isAudio }, maxImages: 12)
                        }

                        if let location = memo.locationIfSet {
                            Label(location.placeholder.isEmpty ? String(localized: "Location") : location.placeholder, systemImage: "mappin.and.ellipse")
                                .font(.metadata)
                                .foregroundStyle(.ink2)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(location.placeholder.isEmpty ? Text("Location") : Text("Location, \(location.placeholder)"))
                        }

                        if let linkPreview {
                            LinkPreviewCard(metadata: linkPreview)
                        }
                    }
                }
                .id(memo.name)

                if !memo.reactions.isEmpty {
                    ReactionSummary(memo: memo) { emoji in
                        Task { await toggleReaction(emoji, on: memo) }
                    }
                }

                CommentsSection(
                    comments: comments,
                    loaded: commentsLoaded,
                    online: session.isOnline,
                    onEdit: { editingComment = EditableComment(memo: $0) },
                    onDelete: { commentToDelete = $0 }
                )
                .confirmationDialog(
                    "Delete this comment?",
                    isPresented: Binding(get: { commentToDelete != nil }, set: { if !$0 { commentToDelete = nil } }),
                    titleVisibility: .visible,
                    presenting: commentToDelete
                ) { comment in
                    Button("Delete", role: .destructive) {
                        Task { await deleteComment(comment) }
                    }
                } message: { _ in
                    Text("It’s removed for everyone who can read this memo.")
                }
            }
            .padding(Metrics.timelineInset)
            .padding(.bottom, 80)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            DetailBar(memo: memo, pickerOpen: $reactionPickerOpen, onReact: { emoji in await toggleReaction(emoji, on: memo) }, onComment: { text in await comment(text, on: memo) })
                .padding(.horizontal, Metrics.timelineInset)
                .padding(.bottom, 8)
        }
        .overlay(alignment: .top) {
            if let notice {
                Text(notice)
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(in: .capsule)
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    // Each new message gets its full time on screen.
                    .task(id: notice) {
                        // Cancelled by the next message, which mustn't be cleared early.
                        guard (try? await Task.sleep(for: .seconds(2.5))) != nil else { return }
                        withAnimation(.memosSpring) { self.notice = nil }
                    }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    MemoActions(memo: memo, onReact: { withAnimation(.memosSpring) { reactionPickerOpen = true } })
                    Button("Create Share Link", systemImage: "link.badge.plus") {
                        Task { await createShareLink(memo) }
                    }
                    .disabled(!session.isOnline)
                    if isMine {
                        Menu("Move to", systemImage: "square.stack") {
                            Button("No Space") { session.store.setAudience(memo.name, visibility: memo.visibility, space: nil) }
                            ForEach(session.store.profile.spaces, id: \.name) { space in
                                Button(space.title) {
                                    session.store.setAudience(memo.name, visibility: VisibilityRules.afterAddingSpace(memo.visibility), space: space.name)
                                }
                            }
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .confirmationDialog("Delete this memo?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                session.store.delete(memo.name)
                dismiss()
            }
        } message: {
            Text("It’s removed everywhere, along with its comments.")
        }
        .sheet(item: Binding(get: { shareURL.map(IdentifiedURL.init) }, set: { shareURL = $0?.url })) { item in
            ShareLinkSheet(url: item.url)
                .presentationDetents([.height(220)])
        }
        .sheet(item: $editingComment) { item in
            CommentEditor(original: item.memo.content) { text in
                await editComment(item.memo, to: text)
            }
            // Medium leaves the top of the memo, where errors appear, in view.
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: Loading

    private func load() async {
        if memo == nil || session.isOnline {
            do {
                try await session.engine.refresh(name)
            } catch {
                if error.code == .notFound || error.code == .permissionDenied { missing = true }
                if memo == nil && !error.isConnectivity { missing = true }
            }
        }
        await loadComments()
        await loadLinkPreview()
    }

    private func loadComments() async {
        guard session.isOnline else {
            commentsLoaded = true
            return
        }
        var request = Memos_Api_ListMemoCommentsRequest()
        request.parent = name
        request.pageSize = 200
        request.orderBy = "create_time asc"
        if let response = try? await session.client.call(session.client.memos.listMemoComments(request:headers:), request) {
            // Oldest first, like a conversation. The server ignores order_by here.
            withAnimation(.memosSpring) { comments = response.comments.sorted { $0.createTime.date < $1.createTime.date } }
        }
        commentsLoaded = true
    }

    private func loadLinkPreview() async {
        guard let memo, let url = Self.firstLink(in: memo.content) else { return }
        if let cached = session.linkPreviews[url] {
            linkPreview = cached
            return
        }
        guard session.isOnline else { return }
        var request = Memos_Api_GetLinkMetadataRequest()
        request.url = url
        if let metadata = try? await session.client.call(session.client.memos.getLinkMetadata(request:headers:), request),
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

    private func toggleReaction(_ emoji: String, on memo: Memo) async {
        guard session.isOnline else {
            show("Connect to react.")
            return
        }
        do {
            if let existing = memo.reactions.first(where: { $0.reactionType == emoji && $0.creator == session.user }) {
                var request = Memos_Api_DeleteMemoReactionRequest()
                request.name = existing.name
                _ = try await session.client.call(session.client.memos.deleteMemoReaction(request:headers:), request)
            } else {
                var request = Memos_Api_UpsertMemoReactionRequest()
                request.parent = memo.name
                request.reaction.reactionType = emoji
                _ = try await session.client.call(session.client.memos.upsertMemoReaction(request:headers:), request)
            }
            _ = try? await session.engine.refresh(memo.name)
        } catch {
            show(error.isConnectivity ? "Connect to react." : "Couldn’t react: \(error.description)" as LocalizedStringResource)
        }
    }

    /// Comments send only when online, so nobody receives one hours after you thought you sent it.
    private func comment(_ text: String, on memo: Memo) async -> Bool {
        guard session.isOnline else {
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
            let created = try await session.client.call(session.client.memos.createMemoComment(request:headers:), request)
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
        guard session.isOnline else {
            show("Connect to edit comments.")
            return false
        }
        var request = Memos_Api_UpdateMemoRequest()
        request.memo.name = comment.name
        request.memo.content = text
        // The server moves `update_time` only when the mask asks, as the sync engine does for memos.
        request.updateMask.paths = ["content", "update_time"]
        do {
            let updated = try await session.client.call(session.client.memos.updateMemo(request:headers:), request)
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
        guard session.isOnline else {
            show("Connect to delete comments.")
            return
        }
        var request = Memos_Api_DeleteMemoRequest()
        request.name = comment.name
        do {
            _ = try await session.client.call(session.client.memos.deleteMemo(request:headers:), request)
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
        _ = try? await session.engine.refresh(name)
    }

    private func createShareLink(_ memo: Memo) async {
        var request = Memos_Api_CreateMemoShareRequest()
        request.parent = memo.name
        do {
            let share = try await session.client.call(session.client.memos.createMemoShare(request:headers:), request)
            let token = ResourceName.lastSegment(share.name)
            shareURL = session.client.serverURL.appending(path: "memos/shares/\(token)")
        } catch {
            if error.isConnectivity {
                show("Connect to create a share link.")
            } else {
                show(verbatim: error.description)
            }
        }
    }

    private func show(_ message: LocalizedStringResource) {
        show(verbatim: String(localized: message))
    }

    /// For text that is already in the reader's language, such as a server's error message.
    private func show(verbatim message: String) {
        withAnimation(.memosSpring) { notice = message }
    }
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
        VStack(alignment: .leading, spacing: 8) {
            Label("Edited on another device. Your version was saved separately.", systemImage: "arrow.triangle.branch")
                .font(.subheadline)
                .foregroundStyle(.ink)
            HStack {
                if let other = session.store.conflictCounterpart(of: memo.name) {
                    Button("Open the other version") { session.path.append(.memo(other)) }
                }
                Spacer()
                Button("Dismiss") { session.store.dismissConflict(memo.name) }
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(12)
        .background(.well, in: .rect(cornerRadius: 12))
    }
}

private struct LinkPreviewCard: View {
    let metadata: Memos_Api_LinkMetadata
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: metadata.url) { openURL(url) }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metadata.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ink)
                        .lineLimit(2)
                    Text(URL(string: metadata.url)?.host() ?? metadata.url)
                        .font(.metadata)
                        .foregroundStyle(.ink2)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.ink2)
            }
            .padding(12)
            .cardBackground()
        }
        .buttonStyle(.plain)
    }
}

private struct CommentsSection: View {
    let comments: [Memo]
    let loaded: Bool
    let online: Bool
    var onEdit: (Memo) -> Void
    var onDelete: (Memo) -> Void
    @Environment(AccountSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !comments.isEmpty {
                Text("\(comments.count) comments")
                    .font(.headline)
                    .foregroundStyle(.ink)
                    .padding(.top, 8)
            }
            ForEach(comments, id: \.name) { comment in
                HStack(alignment: .top, spacing: 10) {
                    Avatar(name: session.people.name(for: comment.creator), size: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(session.people.name(for: comment.creator))
                                .font(.subheadline.weight(.semibold))
                            Text(MemoDate.short(comment.createdAt))
                                .font(.metadata)
                                .foregroundStyle(.ink2)
                        }
                        SensitiveContent(memo: comment) {
                            MemoContentView(content: comment.content, showsTitle: false)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 8))
                .contextMenu { actions(for: comment) }
                .accessibilityActions { actions(for: comment) }
            }
            if loaded && !online && comments.isEmpty {
                Text("Comments load when you’re online.")
                    .font(.metadata)
                    .foregroundStyle(.ink2)
            }
        }
    }

    /// Only for your own comments: the server lets nobody else change them, admins aside.
    @ViewBuilder
    private func actions(for comment: Memo) -> some View {
        if comment.creator == session.user {
            Button("Edit", systemImage: "pencil") { onEdit(comment) }
                .disabled(!online)
            Button("Delete", systemImage: "trash", role: .destructive) { onDelete(comment) }
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
                .padding(.horizontal, Metrics.timelineInset - 5)
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
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if pickerOpen {
                    HStack(spacing: 4) {
                        ForEach(session.store.profile.reactionChoices, id: \.self) { emoji in
                            Button {
                                reacted += 1
                                withAnimation(pickerAnimation) { pickerOpen = false }
                                Task { await onReact(emoji) }
                            } label: {
                                Text(emoji)
                                    .font(.title2)
                                    .frame(width: 40, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("React with \(emoji)")
                        }
                        Button {
                            withAnimation(pickerAnimation) { pickerOpen = false }
                        } label: {
                            Image(systemName: "xmark").frame(width: 32, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close reactions")
                    }
                    .padding(.horizontal, 8)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("react", in: glass)
                } else {
                    Button {
                        withAnimation(pickerAnimation) { pickerOpen = true }
                    } label: {
                        Image(systemName: "face.smiling")
                            .font(.title3)
                            .frame(width: 48, height: 48)
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
                                Image(systemName: sending ? "ellipsis" : "arrow.up.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.memosBlue)
                            }
                            .disabled(sending)
                            .accessibilityLabel("Send comment")
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("comment", in: glass)

                    ShareLink(item: session.webURL(for: memo), subject: Text(memo.displayTitle), message: Text(memo.previewText)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("share", in: glass)
                    .accessibilityLabel("Share")
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: reacted)
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

private struct ShareLinkSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text("Anyone with this link can read the memo.")
                .font(.subheadline)
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
        .padding()
    }
}
