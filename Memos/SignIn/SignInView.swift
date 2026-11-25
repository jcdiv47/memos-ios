import AuthenticationServices
import CryptoKit
import MemosCore
import SwiftUI

/// First run: the three ways in, side by side. Two sign in to your own Memos server, with a
/// password or with an access token; the third keeps memos on this device with no server at all.
/// Each person runs their own instance, so each sign-in screen asks for the address too.
struct SignInView: View {
    /// The instance to sign back in to after the session expired.
    var resuming: URL?
    /// Presented from the on-device library's Settings to add a server; it can be cancelled, and
    /// doesn't offer the library you're already in.
    var connecting = false

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var lookup = ServerLookup()
    @State private var path: [SignInRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if resuming != nil {
                    // Signing back in stays on the same server and the same way in.
                    PasswordForm(resuming: true, prefilledUser: model.session?.store.profile.user?.username)
                } else {
                    MethodChooser(showsOnDevice: !connecting)
                }
            }
            // The navigation container's own view is the system background, black in dark mode,
            // and shows wherever a screen is shortened for the keyboard mid-transition.
            .background(NavigationBackdrop().frame(width: 0, height: 0).accessibilityHidden(true))
            .navigationDestination(for: SignInRoute.self) { route in
                switch route {
                case .password: PasswordForm()
                case .token: TokenForm(isServerLocked: resuming != nil)
                case .onDevice: OnDeviceIntro()
                }
            }
            .toolbar {
                if connecting {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel) { dismiss() }
                    }
                }
            }
        }
        .environment(lookup)
        .task {
            lookup.model = model
            if let resuming, lookup.instance == nil {
                lookup.text = resuming.absoluteString
                await lookup.check()
            }
        }
    }

    struct InstanceInfo {
        var url: URL
        var client: MemosClient
        var profile: Memos_Api_InstanceProfile
        var general: Memos_Api_InstanceSetting.GeneralSetting
        var providers: [Memos_Api_IdentityProvider]

        var title: String {
            let title = general.customProfile.title
            return title.isEmpty ? (url.host() ?? url.absoluteString) : title
        }

        /// Whether to offer a password: the server allows it, or it offers nothing else.
        var allowsPassword: Bool { !general.disallowPasswordAuth || providers.isEmpty }
    }
}

enum SignInRoute: Hashable {
    case password, token, onDevice
}

// MARK: Choosing a way in

/// The first screen: where your memos live, and how you get to them.
private struct MethodChooser: View {
    var showsOnDevice: Bool

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    AppMark()
                        .padding(.bottom, Spacing.xl)
                    Text("Memos")
                        .font(.largeTitleSerif)
                        .foregroundStyle(.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                // Padding rather than a row inset: the row clips at its inset, and the serif
                // overhangs it. It lines up with the section headers below.
                .padding(.horizontal, Spacing.xl + Spacing.xs)
                .padding(.bottom, Spacing.l)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                NavigationLink(value: SignInRoute.password) {
                    MethodRow(
                        systemImage: "person",
                        title: "Username & password",
                        detail: "The account you use on the web. Single sign-on works here too."
                    )
                }
                NavigationLink(value: SignInRoute.token) {
                    MethodRow(
                        systemImage: "key",
                        title: "Access token",
                        detail: "Paste a token from Settings on the web. Best when passwords are off."
                    )
                }
            } header: {
                GroupHeader(title: "On your Memos server", detail: "Syncs everywhere")
            }
            .cardRows()

            if showsOnDevice {
                Section {
                    NavigationLink(value: SignInRoute.onDevice) {
                        MethodRow(
                            systemImage: ThisDevice.symbol,
                            isNeutral: true,
                            title: "Use on this iPhone",
                            detail: "Start writing now. Memos never leave this device."
                        )
                    }
                } header: {
                    GroupHeader(title: "Without a server", detail: "No account")
                }
                .cardRows()
            }
        }
        .paperBackground()
        // The bar stays, empty, rather than hidden: hiding it here would make it slide in and out
        // with every push and pop.
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A heading over a group of ways in, with what they have in common on the right.
private struct GroupHeader: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.sectionTitle)
                .foregroundStyle(.ink2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Spacing.m)
            Text(detail)
                .font(.metadata)
                .foregroundStyle(.ink3)
        }
        .textCase(nil)
    }
}

/// One way in: a symbol, what it is, and when to pick it.
private struct MethodRow: View {
    let systemImage: String
    var isNeutral = false
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(spacing: Spacing.l) {
            IconTile(systemImage: systemImage, isNeutral: isNeutral)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.rowTitle.weight(.semibold))
                    .foregroundStyle(.ink)
                Text(detail)
                    .font(.metadata)
                    .foregroundStyle(.ink2)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: The server

/// The address being typed, and the instance behind it once it answers. Shared by the password
/// and token screens, so switching between them keeps what you typed.
@Observable
final class ServerLookup {
    var text = "" {
        didSet { if text != oldValue { error = nil } }
    }
    private(set) var instance: SignInView.InstanceInfo?
    private(set) var isChecking = false
    var error: String?
    @ObservationIgnored weak var model: AppModel?

    /// The instance, if it is the one at the address as typed now.
    var verified: SignInView.InstanceInfo? {
        guard let instance, MemosClient.normalizedServerURL(text) == instance.url else { return nil }
        return instance
    }

    /// The host as typed, for instructions that name the server.
    var host: String? {
        MemosClient.normalizedServerURL(text)?.host()
    }

    /// Looks the address up, or returns the instance already found there.
    @discardableResult
    func check() async -> SignInView.InstanceInfo? {
        if let verified { return verified }
        guard !isChecking, let model else { return nil }
        guard let url = MemosClient.normalizedServerURL(text) else {
            error = String(localized: "That doesn’t look like a server address.")
            return nil
        }
        isChecking = true
        error = nil
        defer { isChecking = false }

        let client = model.makeClient(for: url)
        do {
            guard try await client.detectDialect() != nil else {
                error = String(localized: "That address doesn’t answer like a Memos server. Check the address; the app needs Memos \(ServerDialect.oldestSupportedRelease) or later.")
                return nil
            }
            let profile = try await client.callPublic(client.instance.getInstanceProfile(request:headers:), Memos_Api_GetInstanceProfileRequest())
            guard ServerDialect.supports(version: profile.version) else {
                error = String(localized: "This server runs Memos \(profile.version). The app needs \(ServerDialect.oldestSupportedRelease) or later; update the server to the latest release.")
                return nil
            }
            if profile.needsSetup {
                error = String(localized: "This server hasn’t been set up yet. Create the first account on the web, then come back.")
                return nil
            }
            var generalRequest = Memos_Api_GetInstanceSettingRequest()
            generalRequest.name = "instance/settings/GENERAL"
            let general = (try? await client.callPublic(client.instance.getInstanceSetting(request:headers:), generalRequest))?.generalSetting ?? .init()
            let providers = (try? await client.callPublic(client.identityProviders.listIdentityProviders(request:headers:), Memos_Api_ListIdentityProvidersRequest()))?.identityProviders ?? []
            let instance = SignInView.InstanceInfo(url: url, client: client, profile: profile, general: general, providers: providers)
            // The address may have changed while it was being looked up.
            guard MemosClient.normalizedServerURL(text) == url else { return nil }
            self.instance = instance
            return instance
        } catch let apiError {
            if url.scheme == "https", apiError.isConnectivity, !text.contains("://") {
                if let host = url.host() {
                    error = String(localized: "Couldn’t reach \(host) over HTTPS. If it uses plain HTTP, type http:// in front.")
                } else {
                    error = String(localized: "Couldn’t reach the server over HTTPS. If it uses plain HTTP, type http:// in front.")
                }
            } else if apiError.code == .unimplemented || apiError.code == .notFound {
                error = String(localized: "This server runs a version of Memos the app doesn’t support. Update it to the latest release.")
            } else {
                error = String(localized: "Couldn’t reach that server. \(apiError.description)")
            }
            return nil
        }
    }
}

/// The address, with the server's version beside it once it answers. Looks the server up when
/// you move on from the field, so the next fields can adapt before you get there.
private struct ServerSection<Focus: Hashable>: View {
    var isLocked = false
    var focus: FocusState<Focus?>.Binding
    let field: Focus
    let next: Focus

    @Environment(ServerLookup.self) private var lookup

    var body: some View {
        @Bindable var lookup = lookup
        Section {
            HStack(spacing: Spacing.m) {
                TextField(text: $lookup.text, prompt: Text(verbatim: "memos.example.com")) { Text("Server address") }
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused(focus, equals: field)
                    .onSubmit {
                        focus.wrappedValue = next
                        Task { await lookup.check() }
                    }
                    .disabled(isLocked)
                    .foregroundStyle(.ink)
                status
            }
        } header: {
            FieldLabel("Server")
        } footer: {
            if let error = lookup.error {
                Text(error).foregroundStyle(.danger)
            }
        }
        .cardRows()
        .onChange(of: focus.wrappedValue) { old, new in
            if old == field, new != field, !lookup.text.trimmingCharacters(in: .whitespaces).isEmpty {
                Task { await lookup.check() }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if lookup.isChecking {
            ProgressView()
        } else if let instance = lookup.verified {
            Label {
                // The release only: a dev build's suffix would crowd out the address.
                Text(verbatim: release(instance.profile.version).map { "Memos \($0)" } ?? "Memos")
            } icon: {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
            }
            .labelStyle(.compact)
            .font(.metadata)
            .foregroundStyle(.memosBlue)
            .fixedSize()
            .transition(.opacity)
        }
    }

    private func release(_ version: String) -> String? {
        let release = version.split(separator: "-").first.map(String.init) ?? version
        return release.isEmpty ? nil : release
    }
}

/// The small label over a field: Server, Account.
private struct FieldLabel: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.metadata.weight(.medium))
            .foregroundStyle(.ink2)
            .textCase(nil)
    }
}

/// A sign-in screen's title, in a header rather than a row: rows clip the serif's overhang.
private struct ScreenTitle: View {
    let title: Text
    var message: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            title
                .font(.largeTitleSerif)
                .foregroundStyle(.ink)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .font(.supporting)
                    .foregroundStyle(.ink2)
            }
        }
        .textCase(nil)
        .padding(.bottom, Spacing.m)
    }
}

extension View {
    /// Raises the keyboard once a pushed screen has landed, and lowers it as soon as the screen
    /// starts to leave. Otherwise the keyboard rides sideways with the screen through the
    /// transition, over bare window, and the form resizes for it mid-flight. `viewDidAppear` fires
    /// only after the push finishes; `viewWillDisappear` before the pop starts moving.
    func focusAfterPush(_ focus: @escaping () -> Void) -> some View {
        background(DidAppear(action: focus).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// Paints the screen's hosting view and the navigation controller around it in Paper.
private struct NavigationBackdrop: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            paint()
        }

        private func paint() {
            parent?.view.backgroundColor = .paper
            navigationController?.view.backgroundColor = .paper
        }
    }
}

/// Calls back from `viewDidAppear`, which SwiftUI's `onAppear` fires well before, and ends
/// editing from `viewWillDisappear`.
private struct DidAppear: UIViewControllerRepresentable {
    let action: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller(action: action) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.action = action }

    final class Controller: UIViewController {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            // The screen's hosting view is the system background, black in dark mode, and shows
            // below the content while the keyboard animates.
            parent?.view.backgroundColor = .paper
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            action()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            view.window?.endEditing(true)
        }
    }
}

// MARK: Username and password

private struct PasswordForm: View {
    var resuming = false
    var prefilledUser: String?

    @Environment(AppModel.self) private var model
    @Environment(ServerLookup.self) private var lookup
    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case server, username, password }

    /// Until the server answers, assume it takes a password, as most do.
    private var allowsPassword: Bool { lookup.verified?.allowsPassword ?? true }

    var body: some View {
        Form {
            Section {
            } header: {
                if resuming, let instance = lookup.instance {
                    ScreenTitle(title: Text(verbatim: instance.title), message: "Sign in again to keep syncing. Nothing on this iPhone was lost.")
                } else {
                    ScreenTitle(title: Text("Sign in"))
                }
            }

            ServerSection(isLocked: resuming, focus: $focus, field: .server, next: .username)

            if allowsPassword {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await signIn() } }
                } header: {
                    FieldLabel("Account")
                } footer: {
                    if let error { Text(error).foregroundStyle(.danger) }
                }
                .cardRows()

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        WideButtonLabel(title: "Sign In", isWorking: isSigningIn)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!canSignIn)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    NavigationLink(value: SignInRoute.token) {
                        Label("Use an Access Token", systemImage: "key")
                    }
                } footer: {
                    Text("This server has passwords turned off. Sign in with single sign-on or an access token.")
                }
                .cardRows()
            }

            // Only where the server offers it, so most people never see an empty promise.
            if let providers = lookup.verified?.providers, !providers.isEmpty {
                Section {
                    ForEach(providers, id: \.name) { provider in
                        Button {
                            Task { await signIn(with: provider) }
                        } label: {
                            Label("Continue with \(provider.title)", systemImage: "person.badge.key")
                        }
                        .disabled(isSigningIn)
                    }
                } footer: {
                    if let error, !allowsPassword {
                        Text(error).foregroundStyle(.danger)
                    } else {
                        Text("Your server’s administrator needs to allow memos://auth/callback as a redirect address for single sign-on.")
                    }
                }
                .cardRows()
            }

            // Signing back in has no chooser to go back to, so the other way in is here.
            if resuming && allowsPassword {
                Section {
                    NavigationLink(value: SignInRoute.token) {
                        Label("Use an Access Token", systemImage: "key")
                    }
                }
                .cardRows()
            }
        }
        .listSectionSpacing(.compact)
        .paperBackground()
        .animation(.memosSpring, value: lookup.verified != nil)
        .animation(.memosSpring, value: allowsPassword)
        .onAppear {
            if let prefilledUser, username.isEmpty { username = prefilledUser }
        }
        .focusAfterPush {
            if lookup.text.isEmpty {
                focus = .server
            } else {
                focus = username.isEmpty ? .username : .password
            }
        }
    }

    private var canSignIn: Bool {
        !lookup.text.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && !password.isEmpty && !isSigningIn && !lookup.isChecking
    }

    private func signIn() async {
        guard canSignIn else { return }
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }
        // One tap looks the server up and signs in, unless the server turns out to want
        // something other than a password.
        guard let instance = await lookup.check(), instance.allowsPassword else { return }
        do {
            let user = try await instance.client.signIn(username: username.trimmingCharacters(in: .whitespaces), password: password)
            await model.didSignIn(serverURL: instance.url, user: user)
        } catch let apiError {
            switch apiError.code {
            case .unauthenticated, .invalidArgument, .notFound, .permissionDenied:
                error = String(localized: "That username and password don’t match.")
            case .resourceExhausted:
                error = String(localized: "Too many attempts. Wait a minute and try again.")
            default:
                error = apiError.isConnectivity ? String(localized: "Couldn’t reach the server.") : apiError.description
            }
        }
    }

    private func signIn(with provider: Memos_Api_IdentityProvider) async {
        guard let instance = lookup.verified else { return }
        let oauth = provider.config.oauth2Config
        let redirectURI = "memos://auth/callback"
        let verifier = PKCE.verifier()
        let state = UUID().uuidString
        guard var components = URLComponents(string: oauth.authURL) else {
            error = String(localized: "This sign-in method isn’t set up correctly.")
            return
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "client_id", value: oauth.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: oauth.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else { return }
        do {
            let callback = try await WebAuthentication.start(url: url, callbackScheme: "memos")
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value
            else {
                error = String(localized: "Sign-in was cancelled.")
                return
            }
            isSigningIn = true
            defer { isSigningIn = false }
            let user = try await instance.client.signIn(identityProvider: provider.name, code: code, redirectURI: redirectURI, codeVerifier: verifier)
            await model.didSignIn(serverURL: instance.url, user: user)
        } catch let apiError as APIError {
            error = apiError.description
        } catch {
            // The person closed the sign-in window.
        }
    }
}

// MARK: Access token

/// A personal access token, for an instance where passwords are off, or for anyone who'd rather
/// not type one into the app.
private struct TokenForm: View {
    var isServerLocked = false

    @Environment(AppModel.self) private var model
    @Environment(ServerLookup.self) private var lookup
    @State private var token = ""
    @State private var isSigningIn = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case server, token }

    var body: some View {
        Form {
            Section {
            } header: {
                ScreenTitle(title: Text("Use a token"))
            }

            ServerSection(isLocked: isServerLocked, focus: $focus, field: .server, next: .token)

            Section {
                HStack(spacing: Spacing.m) {
                    SecureField(text: $token, prompt: Text(verbatim: "memos_pat_…")) { Text("Access token") }
                        .font(.memoCode)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .token)
                        .submitLabel(.go)
                        .onSubmit { Task { await signIn() } }
                    PasteButton(payloadType: String.self) { strings in
                        guard let pasted = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty else { return }
                        Task { @MainActor in token = pasted }
                    }
                    .labelStyle(.titleOnly)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(.memosBlue)
                    .fixedSize()
                }
            } header: {
                FieldLabel("Access token")
            } footer: {
                if let error { Text(error).foregroundStyle(.danger) }
            }
            .cardRows()

            Section {
                steps
                    .listRowBackground(Color.well)
            }

            Section {
                Button {
                    Task { await signIn() }
                } label: {
                    WideButtonLabel(title: "Sign In with Token", isWorking: isSigningIn)
                }
                .buttonStyle(.glassProminent)
                .disabled(!canSignIn)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .listSectionSpacing(.compact)
        .paperBackground()
        .animation(.memosSpring, value: lookup.verified != nil)
        .focusAfterPush {
            focus = lookup.text.isEmpty ? .server : .token
        }
    }

    /// Where a token comes from, step by step, naming the server where we know it.
    private var steps: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Where to find one")
                .font(.metadata.weight(.semibold))
                .foregroundStyle(.ink)
            if let host = lookup.host {
                Step(number: 1, text: "Open \(host) in a browser and sign in.")
            } else {
                Step(number: 1, text: "Open your Memos server in a browser and sign in.")
            }
            Step(number: 2, text: "Go to Settings → My Account → Access Tokens.")
            Step(number: 3, text: "Create a token, copy it, and paste it above. It works until it expires or you revoke it.")
        }
        .padding(.vertical, Spacing.xs)
    }

    private struct Step: View {
        let number: Int
        let text: LocalizedStringKey

        @ScaledMetric(relativeTo: .footnote) private var numberWidth: CGFloat = 16

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Text(number, format: .number)
                    .fontWeight(.semibold)
                    .foregroundStyle(.memosBlue)
                    .frame(width: numberWidth, alignment: .leading)
                Text(text)
                    .foregroundStyle(.ink2)
            }
            .font(.metadata)
            .accessibilityElement(children: .combine)
        }
    }

    private var canSignIn: Bool {
        !lookup.text.trimmingCharacters(in: .whitespaces).isEmpty
            && !token.trimmingCharacters(in: .whitespaces).isEmpty
            && !isSigningIn && !lookup.isChecking
    }

    private func signIn() async {
        guard canSignIn else { return }
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }
        guard let instance = await lookup.check() else { return }
        do {
            let user = try await instance.client.signIn(accessToken: token)
            await model.didSignIn(serverURL: instance.url, user: user)
        } catch let apiError {
            switch apiError.code {
            case .unauthenticated, .permissionDenied, .invalidArgument:
                error = String(localized: "The server didn’t accept that token. It may have expired or been revoked.")
            default:
                error = apiError.isConnectivity ? String(localized: "Couldn’t reach the server.") : apiError.description
            }
        }
    }
}

// MARK: On this device

/// What keeping memos on this device means, before you commit to it.
private struct OnDeviceIntro: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isOpening = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("On this iPhone")
                        .font(.largeTitleSerif)
                        .foregroundStyle(.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("A private notebook, ready right away. Here’s what that means.")
                        .font(.supporting)
                        .foregroundStyle(.ink2)
                }
                .padding(.bottom, Spacing.xs)

                Fact(systemImage: "person.slash", isNeutral: true, title: "No account", detail: "Nothing to sign up for. Open the app and write.")
                Fact(systemImage: "lock", isNeutral: true, title: "Stays on this iPhone", detail: "Memos never upload, and won’t appear on your other devices.")
                Fact(systemImage: "icloud.and.arrow.up", title: "Add a server later", detail: "Connect one in Settings whenever you like. Its memos are kept apart from these.")
            }
            .padding(.horizontal, Spacing.xl + Spacing.xs + Metrics.screenInset)
            .padding(.top, Spacing.l)
            .readableWidth()
        }
        .background(.paper)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Spacing.l) {
                Button {
                    isOpening = true
                    Task { await model.openOnDevice() }
                } label: {
                    WideButtonLabel(
                        title: model.hasOnDeviceLibrary ? "Continue Writing" : "Start Writing",
                        isWorking: isOpening
                    )
                }
                .buttonStyle(.glassProminent)
                .disabled(isOpening)

                HStack(spacing: Spacing.xs) {
                    Text("Have a server?")
                        .foregroundStyle(.ink2)
                    Button("Sign in instead") { dismiss() }
                        .fontWeight(.medium)
                        .foregroundStyle(.memosBlue)
                }
                .font(.supporting)
            }
            .padding(.horizontal, Metrics.screenInset)
            .padding(.bottom, Spacing.m)
            .readableWidth()
        }
    }

    private struct Fact: View {
        let systemImage: String
        var isNeutral = false
        let title: LocalizedStringKey
        let detail: LocalizedStringKey

        var body: some View {
            HStack(alignment: .top, spacing: Spacing.xl) {
                IconTile(systemImage: systemImage, isNeutral: isNeutral)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title)
                        .font(.rowTitle.weight(.semibold))
                        .foregroundStyle(.ink)
                    Text(detail)
                        .font(.supporting)
                        .foregroundStyle(.ink2)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

enum PKCE {
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Runs an `ASWebAuthenticationSession` and returns its callback URL.
enum WebAuthentication {
    /// The session in progress, kept alive until it calls back.
    private static var current: (session: ASWebAuthenticationSession, anchor: PresentationAnchor)?

    static func start(url: URL, callbackScheme: String) async throws -> URL {
        defer { current = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let anchor = PresentationAnchor()
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme), completionHandler: completion(continuation))
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            current = (session, anchor)
            session.start()
        }
    }

    private nonisolated static func completion(_ continuation: CheckedContinuation<URL, any Error>) -> @Sendable (URL?, (any Error)?) -> Void {
        { callback, error in
            if let callback {
                continuation.resume(returning: callback)
            } else {
                continuation.resume(throwing: error ?? URLError(.cancelled))
            }
        }
    }

    final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return scene?.keyWindow ?? ASPresentationAnchor(windowScene: scene!)
        }
    }
}

/// The app's icon, small, at the top of sign-in. The icon is paper on paper, so a hairline keeps
/// its edge.
private struct AppMark: View {
    private static let side: CGFloat = 72
    /// The icon's corner at this size, in the system's proportion.
    private static let corner: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        Image("AppMark")
            .resizable()
            .frame(width: Self.side, height: Self.side)
            .clipShape(shape)
            .overlay { shape.strokeBorder(.hairline, lineWidth: Stroke.hairline) }
            .shadow(color: Color.ink.opacity(0.08), radius: 8, y: 4)
            .accessibilityHidden(true)
    }
}
