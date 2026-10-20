import MemosCore
import SwiftProtobuf
import SwiftUI

/// Account, preferences, access tokens, sync and signing out. Instance administration and
/// webhooks link out to the web.
struct SettingsView: View {
    @Environment(AccountSession.self) private var session
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var displayName = ""
    @State private var confirmSignOut = false
    @State private var cacheSize: Int64?
    @State private var error: String?

    private var user: User? { session.store.profile.user }

    var body: some View {
        @Bindable var files = session.files
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Avatar(name: user?.displayLabel ?? "?", size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Name", text: $displayName)
                                .font(.headline)
                                .onSubmit { Task { await saveDisplayName() } }
                                .disabled(!session.isOnline)
                            Text(verbatim: "@\(user?.username ?? ResourceName.lastSegment(session.user))")
                                .font(.metadata)
                                .foregroundStyle(.ink2)
                            if let email = user?.email, !email.isEmpty {
                                Text(email)
                                    .font(.metadata)
                                    .foregroundStyle(.ink2)
                            }
                        }
                    }
                }

                Section {
                    Picker("Default visibility", selection: Binding(
                        get: { session.defaultVisibility ?? .private },
                        set: { value in Task { await saveDefaultVisibility(value) } }
                    )) {
                        ForEach([MemoVisibility.private, .protected, .public], id: \.self) { visibility in
                            Label(visibility.label, systemImage: visibility.systemImage).tag(visibility)
                        }
                    }
                    .disabled(!session.isOnline)
                } header: {
                    Text("New memos")
                } footer: {
                    Text("The same setting as on the web. Writing inside a Space narrows Protected and Public to the Space’s members.")
                }

                Section {
                    Toggle("Keep all attachments", isOn: $files.keepAll)
                    if let cacheSize {
                        LabeledContent("Downloaded files", value: cacheSize.formatted(.byteCount(style: .file)))
                    }
                } footer: {
                    Text("Downloads every photo and file for reading offline. Otherwise full-size files are kept as you open them, up to 500 MB.")
                }

                SyncSection()

                Section("Developer") {
                    NavigationLink("Access tokens") { AccessTokensView() }
                    Button("Webhooks") { openURL(session.client.serverURL.appending(path: "setting")) }
                }

                Section {
                    LabeledContent("Server", value: session.client.serverURL.host() ?? session.client.serverURL.absoluteString)
                    if let version = session.store.profile.instance?.version, !version.isEmpty {
                        LabeledContent("Version", value: version)
                    }
                    if user?.role == .admin {
                        Button("Instance administration") { openURL(session.client.serverURL.appending(path: "setting")) }
                    }
                }

                Section {
                    // On the button, so the dialog points at it.
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                            Button("Sign Out", role: .destructive) {
                                dismiss()
                                Task { await model.signOut() }
                            }
                        } message: {
                            Text(signOutMessage)
                        }
                } footer: {
                    if let error { Text(error).foregroundStyle(.danger) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(.paper)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .task {
                displayName = user?.displayName ?? ""
                cacheSize = await session.files.cacheSize()
            }
        }
    }

    private var signOutMessage: String {
        let pending = session.store.outbox.count
        if pending == 0 { return String(localized: "This removes your memos from this iPhone. They stay on your server.") }
        return String(localized: "\(pending) changes haven’t uploaded yet and will be lost. This removes your memos from this iPhone. They stay on your server.")
    }

    private func saveDisplayName() async {
        guard var updated = user, displayName != updated.displayName else { return }
        updated.displayName = displayName
        var request = Memos_Api_UpdateUserRequest()
        request.user = updated
        request.updateMask.paths = ["display_name"]
        do {
            session.store.profile.user = try await session.client.call(session.client.users.updateUser(request:headers:), request)
        } catch {
            self.error = error.description
        }
    }

    /// The `memo_visibility` setting the web uses, so changing it here changes it there too.
    private func saveDefaultVisibility(_ visibility: MemoVisibility) async {
        var request = Memos_Api_UpdateUserSettingRequest()
        request.userSetting.name = "\(session.user)/settings/GENERAL"
        request.userSetting.generalSetting.memoVisibility = visibility.filterValue
        request.updateMask.paths = ["memo_visibility"]
        do {
            _ = try await session.client.call(session.client.users.updateUserSetting(request:headers:), request)
            session.store.profile.defaultVisibility = visibility.filterValue
        } catch {
            self.error = error.description
        }
    }
}

private struct SyncSection: View {
    @Environment(AccountSession.self) private var session

    var body: some View {
        Section {
            LabeledContent("Last synced") {
                if session.engine.isSyncing {
                    ProgressView()
                } else if let last = session.store.state.lastSyncAt {
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        Text(last.formatted(.relative(presentation: .named)))
                    }
                } else {
                    Text("Never")
                }
            }
            LabeledContent("Waiting to upload", value: session.store.outbox.count.formatted())
            ForEach(session.store.outbox.filter { $0.failure != nil }) { change in
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.store.memo(named: change.memo)?.displayTitle ?? change.memo)
                        .font(.subheadline)
                    Text(change.failure ?? "")
                        .font(.metadata)
                        .foregroundStyle(.danger)
                    Button("Discard this change", role: .destructive) { session.store.discardChange(change.id) }
                        .font(.subheadline)
                }
            }
            Button("Sync Now") { Task { await session.engine.sync(fullCompare: true) } }
                .disabled(!session.isOnline || session.engine.isSyncing)
        } header: {
            Text("Sync")
        } footer: {
            if !session.isOnline {
                Text("Offline. Changes to your memos upload when you reconnect.")
            } else if let error = session.engine.lastError {
                Text(error.description).foregroundStyle(.danger)
            }
        }
    }
}

/// Personal access tokens for scripts and other clients.
private struct AccessTokensView: View {
    @Environment(AccountSession.self) private var session
    @State private var tokens: [Memos_Api_PersonalAccessToken] = []
    @State private var isCreating = false
    @State private var description = ""
    @State private var expiresInDays = 30
    @State private var created: String?
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            if let created {
                Section {
                    Text(created)
                        .font(.memoCode)
                        .textSelection(.enabled)
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = created }
                } footer: {
                    Text("Copy it now. It won’t be shown again.")
                }
                .listRowBackground(Color.card)
            }
            Section {
                ForEach(tokens, id: \.name) { token in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(token.description_p.isEmpty ? String(localized: "Token") : token.description_p)
                        Text(detail(token))
                            .font(.metadata)
                            .foregroundStyle(.ink2)
                    }
                }
                .onDelete { offsets in
                    let removed = offsets.map { tokens[$0] }
                    Task { for token in removed { await delete(token) } }
                }
            } footer: {
                if let error { Text(error).foregroundStyle(.danger) }
            }
            .listRowBackground(Color.card)
        }
        .scrollContentBackground(.hidden)
        .background(.paper)
        .overlay {
            if loaded && tokens.isEmpty && created == nil && error == nil {
                ContentUnavailableView(
                    "No Access Tokens",
                    systemImage: "key",
                    description: Text("Tokens let scripts and other apps use your account through the API.")
                )
            }
        }
        .navigationTitle("Access Tokens")
        .toolbar {
            Button("New Token", systemImage: "plus") { isCreating = true }
                .disabled(!session.isOnline)
        }
        .alert("New Access Token", isPresented: $isCreating) {
            TextField("Description", text: $description)
            Button("30 days") { expiresInDays = 30; Task { await create() } }
            Button("1 year") { expiresInDays = 365; Task { await create() } }
            Button("Never expires") { expiresInDays = 0; Task { await create() } }
            Button("Cancel", role: .cancel) {}
        }
        .task { await load() }
    }

    private func detail(_ token: Memos_Api_PersonalAccessToken) -> String {
        let createdDate = token.createTime.date.formatted(date: .abbreviated, time: .omitted)
        var parts = [String(localized: "Created \(createdDate)", comment: "When an access token was created; the date is formatted.")]
        if token.hasExpireTime {
            let date = token.expireTime.date
            let formatted = date.formatted(date: .abbreviated, time: .omitted)
            parts.append(date < .now
                ? String(localized: "expired \(formatted)", comment: "Follows “Created <date> · ” for an access token; the date is formatted.")
                : String(localized: "expires \(formatted)", comment: "Follows “Created <date> · ” for an access token; the date is formatted."))
        }
        if token.hasLastUseTime {
            let used = token.lastUseTime.date.formatted(.relative(presentation: .named))
            parts.append(String(localized: "used \(used)", comment: "When an access token was last used, such as “used 2 days ago”; the relative date is formatted."))
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        var request = Memos_Api_ListPersonalAccessTokensRequest()
        request.parent = session.user
        do {
            tokens = try await session.client.call(session.client.users.listPersonalAccessTokens(request:headers:), request).personalAccessTokens
        } catch {
            self.error = error.isConnectivity ? String(localized: "Connect to manage tokens.") : error.description
        }
        loaded = true
    }

    private func create() async {
        var request = Memos_Api_CreatePersonalAccessTokenRequest()
        request.parent = session.user
        request.description_p = description
        request.expiresInDays = Int32(expiresInDays)
        do {
            let response = try await session.client.call(session.client.users.createPersonalAccessToken(request:headers:), request)
            created = response.token
            description = ""
            await load()
        } catch {
            self.error = error.description
        }
    }

    private func delete(_ token: Memos_Api_PersonalAccessToken) async {
        var request = Memos_Api_DeletePersonalAccessTokenRequest()
        request.name = token.name
        if (try? await session.client.call(session.client.users.deletePersonalAccessToken(request:headers:), request)) != nil {
            tokens.removeAll { $0.name == token.name }
        }
    }
}
