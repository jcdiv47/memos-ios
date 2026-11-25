import MemosCore
import SwiftProtobuf
import SwiftUI

/// Comments, mentions and Space invitations. Opens from the bell, on every instance.
struct InboxView: View {
    @Environment(AccountSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var notifications: [UserNotification] = []
    @State private var loaded = false
    @State private var error: String?
    /// The invitation being joined or declined, so its buttons wait for the answer.
    @State private var answering: String?
    @State private var answered = 0
    @State private var failed = 0

    var body: some View {
        NavigationStack {
            List {
                if !session.isOnline {
                    Text("Connect to see what’s new.")
                        .font(.supporting)
                        .foregroundStyle(.ink2)
                        .listRowBackground(Color.clear)
                }
                ForEach(notifications, id: \.name) { notification in
                    NotificationRow(notification: notification, isAnswering: answering == notification.name) { action in
                        Task { await handle(action, notification) }
                    }
                    .cardRows()
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await delete(notification) }
                        }
                        if notification.status == .unread {
                            Button("Done", systemImage: "checkmark") {
                                Task { await archive(notification) }
                            }
                            .tint(.memosBlue)
                        }
                    }
                }
                if let error {
                    Text(error)
                        .font(.supporting)
                        .foregroundStyle(.danger)
                        .listRowBackground(Color.clear)
                }
            }
            .paperBackground()
            .overlay {
                if loaded && notifications.isEmpty && session.isOnline {
                    ContentUnavailableView("You’re all caught up", systemImage: "bell")
                }
            }
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A sheet you only read closes with a plain X at the trailing edge.
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sensoryFeedback(.success, trigger: answered)
            .sensoryFeedback(.error, trigger: failed)
        }
    }

    private func load() async {
        guard session.isOnline, let client = session.client else {
            loaded = true
            return
        }
        var request = Memos_Api_ListUserNotificationsRequest()
        request.parent = session.user
        do {
            let response = try await client.call(client.users.listUserNotifications(request:headers:), request)
            let sorted = response.notifications.sorted { $0.createTime.date > $1.createTime.date }
            // A reload after an answer settles the rows that changed instead of swapping them.
            if loaded {
                withAnimation(.memosSpring) { notifications = sorted }
            } else {
                notifications = sorted
            }
            for notification in notifications { session.people.remember(notification.senderUser) }
            session.store.profile.unreadNotifications = notifications.count { $0.status == .unread }
            error = nil
        } catch {
            self.error = error.isConnectivity ? nil : error.description
        }
        loaded = true
    }

    enum Action { case open, accept, decline }

    private func handle(_ action: Action, _ notification: UserNotification) async {
        switch action {
        case .open:
            await archive(notification)
            switch notification.payload {
            case .memoComment(let payload): session.show(memo: payload.relatedMemo)
            case .memoMention(let payload): session.show(memo: payload.relatedMemo.isEmpty ? payload.memo : payload.relatedMemo)
            default: break
            }
        case .accept, .decline:
            guard case .spaceInvitation(let payload) = notification.payload, let client = session.client, answering == nil else { return }
            withAnimation(.memosFade) { answering = notification.name }
            defer { withAnimation(.memosFade) { answering = nil } }
            do {
                if action == .accept {
                    var request = Memos_Api_AcceptSpaceInvitationRequest()
                    request.name = payload.spaceInvitation
                    _ = try await client.call(client.spaces.acceptSpaceInvitation(request:headers:), request)
                } else {
                    var request = Memos_Api_DeclineSpaceInvitationRequest()
                    request.name = payload.spaceInvitation
                    _ = try await client.call(client.spaces.declineSpaceInvitation(request:headers:), request)
                }
                await archive(notification)
                await session.engine?.refreshProfile()
                await load()
                answered += 1
            } catch {
                self.error = error.description
                failed += 1
            }
        }
    }

    private func archive(_ notification: UserNotification) async {
        guard notification.status == .unread, let client = session.client else { return }
        var request = Memos_Api_UpdateUserNotificationRequest()
        request.notification.name = notification.name
        request.notification.status = .archived
        request.updateMask.paths = ["status"]
        if let updated = try? await client.call(client.users.updateUserNotification(request:headers:), request),
           let index = notifications.firstIndex(where: { $0.name == updated.name }) {
            withAnimation(.memosFade) { notifications[index].status = updated.status }
            session.store.profile.unreadNotifications = notifications.count { $0.status == .unread }
        }
    }

    private func delete(_ notification: UserNotification) async {
        guard let client = session.client else { return }
        var request = Memos_Api_DeleteUserNotificationRequest()
        request.name = notification.name
        if (try? await client.call(client.users.deleteUserNotification(request:headers:), request)) != nil {
            withAnimation(.memosSpring) { notifications.removeAll { $0.name == notification.name } }
            session.store.profile.unreadNotifications = notifications.count { $0.status == .unread }
        }
    }
}

private struct NotificationRow: View {
    let notification: UserNotification
    /// Join or Decline was tapped and the server hasn't answered yet.
    var isAnswering = false
    var perform: (InboxView.Action) -> Void

    @Environment(AccountSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isPendingInvitation: Bool {
        if case .spaceInvitation(let payload) = notification.payload { return payload.state == .pending }
        return false
    }

    var body: some View {
        if isPendingInvitation {
            // Join and Decline are buttons of their own, which a row button would swallow.
            content
                .contentShape(.rect)
                .onTapGesture { perform(.open) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
        } else {
            // A real button, so the row highlights under the finger like any list row.
            Button { perform(.open) } label: { content }
                .accessibilityElement(children: .combine)
        }
    }

    private var content: some View {
        let sender = notification.senderUser.name.isEmpty ? session.people.name(for: notification.sender) : notification.senderUser.displayLabel
        return HStack(alignment: .top, spacing: Spacing.l) {
            leading
                .overlay(alignment: .topTrailing) {
                    if notification.status == .unread {
                        // Rows sit on cards, so the ring is cut from Card.
                        UnreadDot(ringed: true, ring: .card).offset(x: 2, y: -2)
                    }
                }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(headline(sender))
                    .font(.supporting)
                    .foregroundStyle(.ink)
                if let comment {
                    // What they said, set apart from who said it.
                    Text(comment)
                        .font(.supporting)
                        .foregroundStyle(.ink2)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.l)
                        .padding(.vertical, Spacing.m)
                        .background(.well, in: .rect(cornerRadius: Radius.inner))
                        .padding(.vertical, Spacing.xxs)
                } else if let snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.supporting)
                        .foregroundStyle(.ink2)
                        .lineLimit(2)
                }
                Text(MemoDate.short(notification.createTime.date))
                    .font(.metadata)
                    .foregroundStyle(.ink2)
                if isPendingInvitation {
                    answers
                        .padding(.top, Spacing.xs)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .opacity,
                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)).animation(.memosFade)
                        ))
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Join and Decline: chips, not glass, since they sit on a card among other rows.
    private var answers: some View {
        HStack(spacing: Spacing.m) {
            Button { perform(.accept) } label: {
                // The spinner takes the word's place, so the chip keeps its width.
                ZStack {
                    Text("Join").opacity(isAnswering ? 0 : 1)
                    if isAnswering {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .buttonStyle(.prominentChip)
            Button("Decline") { perform(.decline) }
                .buttonStyle(.chip)
        }
        .disabled(isAnswering)
    }

    /// A Space's invitation leads with the Space, everything else with the person.
    @ViewBuilder
    private var leading: some View {
        if case .spaceInvitation(let payload) = notification.payload {
            SpaceTile(title: payload.space.title)
        } else {
            UserAvatar(user: notification.sender, size: AvatarSize.medium)
        }
    }

    private func headline(_ sender: String) -> AttributedString {
        var name = AttributedString(sender)
        name.font = .emphasis
        switch notification.payload {
        case .memoComment(let payload):
            if let title = Self.title(of: payload.relatedMemo, snippet: payload.relatedMemoSnippet, in: session) {
                return AttributedString(localized: "\(name) commented on \(emphasized(title))", comment: "An Inbox notification: the sender's name, then the title of the memo they commented on.")
            }
            return AttributedString(localized: "\(name) commented on your memo", comment: "An Inbox notification; the sender's name.")
        case .memoMention(let payload):
            // A mention in a comment names the memo the comment is on.
            let memo = payload.relatedMemo.isEmpty ? payload.memo : payload.relatedMemo
            let snippet = payload.relatedMemo.isEmpty ? payload.memoSnippet : payload.relatedMemoSnippet
            if let title = Self.title(of: memo, snippet: snippet, in: session) {
                return AttributedString(localized: "\(name) mentioned you in \(emphasized(title))", comment: "An Inbox notification: the sender's name, then the title of the memo they mentioned you in.")
            }
            return AttributedString(localized: "\(name) mentioned you", comment: "An Inbox notification; the sender's name.")
        case .spaceInvitation(let payload):
            let space = emphasized(payload.space.title)
            switch payload.state {
            case .accepted: return AttributedString(localized: "\(name) added you to \(space)", comment: "An Inbox notification: the sender's name, then a Space's name.")
            default: return AttributedString(localized: "\(name) invited you to \(space)", comment: "An Inbox notification: the sender's name, then a Space's name.")
            }
        default: return name
        }
    }

    private func emphasized(_ text: String) -> AttributedString {
        var text = AttributedString(text)
        text.font = .emphasis
        return text
    }

    /// The memo's title: from the local copy if there is one, else the first line of the
    /// server's snippet. Nil when there's nothing worth naming it by.
    private static func title(of memo: String, snippet: String, in session: AccountSession) -> String? {
        if !memo.isEmpty, let local = session.store.memo(named: memo) {
            let title = local.displayTitle
            if !title.isEmpty { return title }
        }
        let line = typographic(snippet).split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 40 ? String(line.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// A comment's own words, shown in a well under the headline.
    private var comment: String? {
        guard case .memoComment(let payload) = notification.payload, !payload.memoSnippet.isEmpty else { return nil }
        return Self.typographic(payload.memoSnippet)
    }

    private var snippet: String? {
        let text: String? = switch notification.payload {
        case .memoMention(let payload): payload.memoSnippet
        case .spaceInvitation(let payload): payload.space.description_p.isEmpty ? nil : payload.space.description_p
        default: nil
        }
        return text.map(Self.typographic)
    }

    /// The server cuts snippets with “ ...”; set it as one ellipsis against the last word.
    static func typographic(_ snippet: String) -> String {
        guard snippet.hasSuffix("...") else { return snippet }
        return snippet.dropLast(3).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

/// A Space, as the sender of its invitation: its initial on a rounded square, so it never reads
/// as a person.
private struct SpaceTile: View {
    let title: String

    /// Grows with the text beside it, like a person's avatar.
    @ScaledMetric(relativeTo: .subheadline) private var scale = SymbolScale.base

    var body: some View {
        let side = Metrics.scaled(AvatarSize.medium, by: scale)
        Text(title.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: side * 0.45, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(.memosBlue, in: .rect(cornerRadius: Radius.inner))
            .accessibilityHidden(true)
    }
}
