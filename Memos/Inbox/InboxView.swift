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
                    NotificationRow(notification: notification) { action in
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
                    ContentUnavailableView("You’re all caught up", systemImage: "bell", description: Text("Comments, mentions and Space invitations show up here."))
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
            notifications = response.notifications.sorted { $0.createTime.date > $1.createTime.date }
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
            guard case .spaceInvitation(let payload) = notification.payload, let client = session.client else { return }
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
            } catch {
                self.error = error.description
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
    var perform: (InboxView.Action) -> Void

    @Environment(AccountSession.self) private var session

    private var isPendingInvitation: Bool {
        if case .spaceInvitation(let payload) = notification.payload { return payload.state == .pending }
        return false
    }

    var body: some View {
        if isPendingInvitation {
            // Accept and Decline are buttons of their own, which a row button would swallow.
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
            UserAvatar(user: notification.sender, size: AvatarSize.medium)
                .overlay(alignment: .topTrailing) {
                    if notification.status == .unread {
                        UnreadDot(ringed: true).offset(x: 2, y: -2)
                    }
                }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(headline(sender))
                    .font(.supporting)
                    .foregroundStyle(.ink)
                if let snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.supporting)
                        .foregroundStyle(.ink2)
                        .lineLimit(2)
                }
                if case .spaceInvitation(let payload) = notification.payload, payload.state == .pending {
                    HStack(spacing: Spacing.m) {
                        Button("Accept") { perform(.accept) }
                            .buttonStyle(.glassProminent)
                        Button("Decline") { perform(.decline) }
                            .buttonStyle(.glass)
                    }
                    .padding(.top, Spacing.xs)
                }
                Text(MemoDate.short(notification.createTime.date))
                    .font(.metadata)
                    .foregroundStyle(.ink2)
            }
            Spacer(minLength: 0)
        }
    }

    private func headline(_ sender: String) -> AttributedString {
        var name = AttributedString(sender)
        name.font = .emphasis
        switch notification.payload {
        case .memoComment: return AttributedString(localized: "\(name) commented on your memo", comment: "An Inbox notification; the sender's name.")
        case .memoMention: return AttributedString(localized: "\(name) mentioned you", comment: "An Inbox notification; the sender's name.")
        case .spaceInvitation(let payload):
            let space = payload.space.title
            switch payload.state {
            case .accepted: return AttributedString(localized: "\(name) added you to \(space)", comment: "An Inbox notification: the sender's name, then a Space's name.")
            default: return AttributedString(localized: "\(name) invited you to \(space)", comment: "An Inbox notification: the sender's name, then a Space's name.")
            }
        default: return name
        }
    }

    private var snippet: String? {
        let text: String? = switch notification.payload {
        case .memoComment(let payload): payload.memoSnippet
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
