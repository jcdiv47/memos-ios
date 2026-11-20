import AuthenticationServices
import CryptoKit
import MemosCore
import SwiftUI

/// First run: the server address, then the sign-in methods that instance offers (password,
/// SSO, or both). Each person runs their own instance, so the address comes first. The first run
/// also offers the on-device library, for keeping memos with no server at all.
struct SignInView: View {
    /// The instance to sign back in to after the session expired.
    var resuming: URL?
    /// Presented from the on-device library's Settings to add a server; it can be cancelled, and
    /// doesn't offer the library you're already in.
    var connecting = false

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var serverText = ""
    @State private var instance: InstanceInfo?
    @State private var isChecking = false
    @State private var isOpeningOnDevice = false
    @State private var error: String?

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
    }

    var body: some View {
        NavigationStack {
            Group {
                if let instance {
                    CredentialsForm(
                        instance: instance,
                        resuming: resuming != nil,
                        prefilledUser: resuming != nil ? model.session?.store.profile.user?.username : nil,
                        // Signing back in stays on the same server; a first sign-in can still
                        // correct the address.
                        onChangeServer: resuming == nil ? { self.instance = nil } : nil
                    )
                } else {
                    serverForm
                }
            }
            .paperBackground()
            .animation(.memosSpring, value: instance != nil)
            .toolbar {
                if connecting {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel) { dismiss() }
                    }
                }
            }
        }
        .task {
            if let resuming, instance == nil {
                serverText = resuming.absoluteString
                await check()
            }
        }
    }

    private var serverForm: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text("Memos")
                        .font(.largeTitleSerif)
                        .foregroundStyle(.ink)
                    Text("Sign in to your own Memos server. Your notes stay there, and on this iPhone.")
                        .font(.supporting)
                        .foregroundStyle(.ink2)
                }
                // Padding rather than a row inset: the row clips at its inset, and the serif
                // overhangs it. The row also keeps its rounded corners as a mask, which shaved
                // the bottom of the last line's first letter, so the text clears the arc. It
                // lines up with the section headers below, as the next step's title does.
                .padding(.horizontal, Spacing.xl + Spacing.xs)
                .padding(.vertical, Spacing.l)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                TextField(text: $serverText, prompt: Text(verbatim: "memos.example.com")) { Text("Server address") }
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .onSubmit { Task { await check() } }
            } header: {
                Text("Server address")
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.danger)
                } else {
                    Text("The address you open Memos at in a browser.")
                }
            }
            .cardRows()

            Section {
                Button {
                    Task { await check() }
                } label: {
                    WideButtonLabel(title: "Continue", isWorking: isChecking)
                }
                .buttonStyle(.glassProminent)
                .disabled(serverText.trimmingCharacters(in: .whitespaces).isEmpty || isChecking)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if resuming == nil && !connecting {
                onDeviceChoice
            }
        }
    }

    /// The other way in: no server, no account, memos kept on this iPhone only.
    private var onDeviceChoice: some View {
        Section {
            Button {
                isOpeningOnDevice = true
                Task { await model.openOnDevice() }
            } label: {
                WideButtonLabel(
                    title: model.hasOnDeviceLibrary ? "Continue with Memos on This iPhone" : "Use Without a Server",
                    isWorking: isOpeningOnDevice
                )
            }
            .buttonStyle(.glass)
            .disabled(isOpeningOnDevice || isChecking)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } footer: {
            Text("No account needed. Memos stay on this iPhone and never upload. You can add a server later; its memos are kept apart.")
        }
    }

    private func check() async {
        guard let url = MemosClient.normalizedServerURL(serverText) else {
            error = String(localized: "That doesn’t look like a server address.")
            return
        }
        isChecking = true
        error = nil
        defer { isChecking = false }

        let client = model.makeClient(for: url)
        do {
            guard try await client.detectDialect() != nil else {
                error = String(localized: "That address doesn’t answer like a Memos server. Check the address; the app needs Memos \(ServerDialect.oldestSupportedRelease) or later.")
                return
            }
            let profile = try await client.callPublic(client.instance.getInstanceProfile(request:headers:), Memos_Api_GetInstanceProfileRequest())
            guard ServerDialect.supports(version: profile.version) else {
                error = String(localized: "This server runs Memos \(profile.version). The app needs \(ServerDialect.oldestSupportedRelease) or later; update the server to the latest release.")
                return
            }
            if profile.needsSetup {
                error = String(localized: "This server hasn’t been set up yet. Create the first account on the web, then come back.")
                return
            }
            var generalRequest = Memos_Api_GetInstanceSettingRequest()
            generalRequest.name = "instance/settings/GENERAL"
            let general = (try? await client.callPublic(client.instance.getInstanceSetting(request:headers:), generalRequest))?.generalSetting ?? .init()
            let providers = (try? await client.callPublic(client.identityProviders.listIdentityProviders(request:headers:), Memos_Api_ListIdentityProvidersRequest()))?.identityProviders ?? []
            instance = InstanceInfo(url: url, client: client, profile: profile, general: general, providers: providers)
        } catch let apiError {
            if url.scheme == "https", apiError.isConnectivity, serverText.hasPrefix("http://") == false, !serverText.contains("://") {
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
        }
    }
}

private struct CredentialsForm: View {
    let instance: SignInView.InstanceInfo
    var resuming = false
    var prefilledUser: String?
    var onChangeServer: (() -> Void)?

    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var password = ""
    @State private var usesToken = false
    @State private var token = ""
    @State private var tokenError: String?
    @State private var isSigningIn = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case username, password, token }

    var body: some View {
        Form {
            // A header rather than a row: rows clip the serif's overhang.
            Section {
            } header: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    // The same title as the address step, so the two read as one page.
                    Text(instance.title)
                        .font(.largeTitleSerif)
                        .foregroundStyle(.ink)
                    Text(instance.url.absoluteString)
                        .font(.metadata)
                        .foregroundStyle(.ink2)
                    if !instance.profile.version.isEmpty {
                        Text(verbatim: "Memos \(instance.profile.version)")
                            .font(.metadata)
                            .foregroundStyle(.ink2)
                    }
                    if resuming {
                        Text("Sign in again to keep syncing. Nothing on this iPhone was lost.")
                            .font(.supporting)
                            .foregroundStyle(.ink2)
                            .padding(.top, Spacing.m)
                    }
                }
                .textCase(nil)
                .padding(.bottom, Spacing.m)
            }

            if !instance.general.disallowPasswordAuth || instance.providers.isEmpty {
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
                    .disabled(username.isEmpty || password.isEmpty || isSigningIn)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }

            if !instance.providers.isEmpty {
                Section {
                    ForEach(instance.providers, id: \.name) { provider in
                        Button {
                            Task { await signIn(with: provider) }
                        } label: {
                            Label("Continue with \(provider.title)", systemImage: "person.badge.key")
                        }
                    }
                } footer: {
                    Text("Your server’s administrator needs to allow memos://auth/callback as a redirect address for single sign-on.")
                }
                .cardRows()
            }

            tokenSection
        }
        .toolbar {
            if let onChangeServer {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onChangeServer) {
                        // Drawn like the system back button elsewhere in the app.
                        Image(systemName: "chevron.backward")
                            .foregroundStyle(.ink)
                    }
                    .accessibilityLabel("Change Server")
                }
            }
        }
        .onAppear {
            if let prefilledUser, username.isEmpty { username = prefilledUser }
            focus = username.isEmpty ? .username : .password
        }
    }

    /// A personal access token, for an instance where neither password nor SSO suits.
    @ViewBuilder
    private var tokenSection: some View {
        Section {
            if usesToken {
                SecureField(text: $token, prompt: Text(verbatim: "memos_pat_…")) { Text("Access token") }
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .token)
                    .submitLabel(.go)
                    .onSubmit { Task { await signIn(token: token) } }
                Button("Sign In with Token") {
                    Task { await signIn(token: token) }
                }
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || isSigningIn)
            } else {
                Button("Use an Access Token", systemImage: "key") {
                    withAnimation(.memosSpring) { usesToken = true }
                    focus = .token
                }
            }
        } footer: {
            if let tokenError {
                Text(tokenError).foregroundStyle(.danger)
            } else if usesToken {
                Text("Create one on the web in Settings, under Access Tokens. The app stays signed in until the token expires or you revoke it.")
            }
        }
        .cardRows()
    }

    private func signIn(token: String) async {
        isSigningIn = true
        tokenError = nil
        defer { isSigningIn = false }
        do {
            let user = try await instance.client.signIn(accessToken: token)
            await model.didSignIn(serverURL: instance.url, user: user)
        } catch let apiError {
            switch apiError.code {
            case .unauthenticated, .permissionDenied, .invalidArgument:
                tokenError = String(localized: "The server didn’t accept that token. It may have expired or been revoked.")
            default:
                tokenError = apiError.isConnectivity ? String(localized: "Couldn’t reach the server.") : apiError.description
            }
        }
    }

    private func signIn() async {
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }
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
