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
                            Label(location.placeholder.isEmpty ? "Location" : location.placeholder, systemImage: "mappin.and.ellipse")
                                .font(.metadata)
                                .foregroundStyle(.ink2)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(location.placeholder.isEmpty ? "Location" : "Location, \(location.placeholder)")
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

                CommentsSection(comments: comments, loaded: commentsLoaded, online: session.isOnline)
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
            show(error.isConnectivity ? "Connect to react." : "Couldn’t react: \(error.description)")
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
            show(error.isConnectivity ? "Connect to comment." : "Couldn’t comment: \(error.description)")
            return false
        }
    }

    private func createShareLink(_ memo: Memo) async {
        var request = Memos_Api_CreateMemoShareRequest()
        request.parent = memo.name
        do {
            let share = try await session.client.call(session.client.memos.createMemoShare(request:headers:), request)
            let token = ResourceName.lastSegment(share.name)
            shareURL = session.client.serverURL.appending(path: "memos/shares/\(token)")
        } catch {
            show(error.isConnectivity ? "Connect to create a share link." : error.description)
        }
    }

    private func show(_ message: String) {
        withAnimation(.memosSpring) { notice = message }
    }
}

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
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
        .background(.paper2, in: .rect(cornerRadius: 12))
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
    @Environment(AccountSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !comments.isEmpty {
                Text(comments.count == 1 ? "1 comment" : "\(comments.count) comments")
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
            }
            if loaded && !online && comments.isEmpty {
                Text("Comments load when you’re online.")
                    .font(.metadata)
                    .foregroundStyle(.ink2)
            }
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
