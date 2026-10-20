import Connect
import Foundation
import SwiftProtobuf

/// The Connect client for one Memos instance, with the session handling the web client does:
/// a short-lived access token in memory, refreshed through the `memos_refresh` cookie before it
/// expires and once more when a call comes back unauthenticated.
///
/// The refresh cookie is captured from `Set-Cookie` and sent back by hand rather than through
/// `HTTPCookieStorage`, so it lives in the ``CredentialStore`` (the Keychain in the app) and is
/// shared with the app's extensions.
public final class MemosClient: Sendable {
    public let serverURL: URL

    public let auth: Memos_Api_AuthServiceClient
    public let memos: Memos_Api_MemoServiceClient
    public let users: Memos_Api_UserServiceClient
    public let spaces: Memos_Api_SpaceServiceClient
    public let attachments: Memos_Api_AttachmentServiceClient
    public let instance: Memos_Api_InstanceServiceClient
    public let identityProviders: Memos_Api_IdentityProviderServiceClient
    public let ai: Memos_Api_AiserviceClient

    private let session: SessionKeeper
    private let dialectState: DialectState

    /// - Parameter onSessionExpired: Called when the refresh token is rejected and the user has
    ///   to sign in again. Not called for connectivity failures.
    public init(
        serverURL: URL,
        credentialStore: CredentialStore,
        onSessionExpired: @escaping @Sendable () -> Void = {}
    ) {
        self.serverURL = serverURL

        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        let saved = credentialStore.load()
        dialectState = DialectState(saved?.serverURL == serverURL ? saved?.dialect ?? .current : .current)
        let protocolClient = ProtocolClient(
            httpClient: DialectHTTPClient(base: URLSessionHTTPClient(configuration: configuration), state: dialectState),
            config: ProtocolClientConfig(
                host: serverURL.absoluteString,
                networkProtocol: .connect,
                codec: DialectCodec(state: dialectState),
                timeout: 60
            )
        )
        auth = Memos_Api_AuthServiceClient(client: protocolClient)
        memos = Memos_Api_MemoServiceClient(client: protocolClient)
        users = Memos_Api_UserServiceClient(client: protocolClient)
        spaces = Memos_Api_SpaceServiceClient(client: protocolClient)
        attachments = Memos_Api_AttachmentServiceClient(client: protocolClient)
        instance = Memos_Api_InstanceServiceClient(client: protocolClient)
        identityProviders = Memos_Api_IdentityProviderServiceClient(client: protocolClient)
        ai = Memos_Api_AiserviceClient(client: protocolClient)
        session = SessionKeeper(
            serverURL: serverURL,
            store: credentialStore,
            auth: auth,
            onSessionExpired: onSessionExpired
        )
    }

    /// Normalizes what someone types into the server field: adds `https://` when no scheme is
    /// given and drops a trailing slash, keeping any sub-path the instance is served under.
    public static func normalizedServerURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil
        else { return nil }
        return url
    }

    // MARK: Server API

    /// The API this client speaks to the server.
    public var dialect: ServerDialect { dialectState.current }

    /// Finds out which API the server speaks and switches to it, before signing in. Nil when
    /// neither answers like Memos: the address is wrong, or the server is older than 0.31.
    public func detectDialect() async throws(APIError) -> ServerDialect? {
        var connectivityError: APIError?
        for dialect in [ServerDialect.current, .v1] {
            var request = URLRequest(url: serverURL.appending(path: "\(dialect.package).InstanceService/GetInstanceProfile"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
            request.timeoutInterval = 15
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                // A server without this route answers with its web app's HTML instead.
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true {
                    dialectState.current = dialect
                    return dialect
                }
            } catch {
                connectivityError = APIError(code: .unavailable, message: error.localizedDescription)
            }
        }
        if let connectivityError { throw connectivityError }
        return nil
    }

    // MARK: Calls

    /// Sends an authenticated request. Refreshes the access token first when it is about to
    /// expire, and retries once after a refresh when the server answers `unauthenticated`.
    public func call<Output: ProtobufMessage>(
        _ send: @Sendable (Headers) async -> ResponseMessage<Output>
    ) async throws(APIError) -> Output {
        let token = try await session.validAccessToken()
        let response = await send(Self.headers(bearer: token))
        switch response.result {
        case .success(let output):
            return output
        case .failure(let error) where error.code == .unauthenticated:
            let refreshed = try await session.refresh(replacing: token)
            let retry = await send(Self.headers(bearer: refreshed))
            switch retry.result {
            case .success(let output): return output
            case .failure(let error): throw APIError(error)
            }
        case .failure(let error):
            throw APIError(error)
        }
    }

    /// Sends `request` through a generated client method, authenticated:
    /// `try await client.call(client.memos.getMemo(request:headers:), request)`.
    public func call<Input: ProtobufMessage, Output: ProtobufMessage>(
        _ method: @escaping @Sendable (Input, Headers) async -> ResponseMessage<Output>,
        _ request: Input
    ) async throws(APIError) -> Output {
        try await call { headers in await method(request, headers) }
    }

    /// Sends a request that needs no session, such as reading the instance profile before
    /// signing in or opening a share link.
    public func callPublic<Output: ProtobufMessage>(
        _ send: @Sendable (Headers) async -> ResponseMessage<Output>
    ) async throws(APIError) -> Output {
        switch await send([:]).result {
        case .success(let output): return output
        case .failure(let error): throw APIError(error)
        }
    }

    public func callPublic<Input: ProtobufMessage, Output: ProtobufMessage>(
        _ method: @escaping @Sendable (Input, Headers) async -> ResponseMessage<Output>,
        _ request: Input
    ) async throws(APIError) -> Output {
        try await callPublic { headers in await method(request, headers) }
    }

    /// The access token for requests made outside Connect, such as loading attachment files.
    public func accessToken() async throws(APIError) -> String {
        try await session.validAccessToken()
    }

    public var credentials: Credentials? {
        get async { await session.credentials }
    }

    /// Headers for a plain `URLRequest` to the instance's file server.
    public func authorizedRequest(for url: URL) async throws(APIError) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: Sign-in

    public func signIn(username: String, password: String) async throws(APIError) -> Memos_Api_User {
        var credentials = Memos_Api_SignInRequest.PasswordCredentials()
        credentials.username = username
        credentials.password = password
        var request = Memos_Api_SignInRequest()
        request.passwordCredentials = credentials
        return try await signIn(request)
    }

    public func signIn(
        identityProvider: String,
        code: String,
        redirectURI: String,
        codeVerifier: String?
    ) async throws(APIError) -> Memos_Api_User {
        var credentials = Memos_Api_SignInRequest.SsoCredentials()
        credentials.identityProvider = identityProvider
        credentials.code = code
        credentials.redirectUri = redirectURI
        if let codeVerifier {
            credentials.codeVerifier = codeVerifier
        }
        var request = Memos_Api_SignInRequest()
        request.ssoCredentials = credentials
        return try await signIn(request)
    }

    /// Signs in with a personal access token, for instances where password sign-in is off or
    /// for an account set up without one. The token stands in for the access token until it
    /// expires or is revoked; with no refresh cookie, the session ends when the server rejects it.
    public func signIn(accessToken: String) async throws(APIError) -> Memos_Api_User {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = await auth.getCurrentUser(request: Memos_Api_GetCurrentUserRequest(), headers: Self.headers(bearer: token))
        switch response.result {
        case .success(let output) where output.hasUser && !output.user.name.isEmpty:
            await session.store(Credentials(
                serverURL: serverURL,
                user: output.user.name,
                accessToken: token,
                accessTokenExpiry: .distantFuture,
                refreshToken: nil,
                dialect: dialect
            ))
            return output.user
        case .success:
            throw APIError(code: .unauthenticated, message: String(localized: "The server didn’t accept the token.", bundle: .module))
        case .failure(let error):
            throw APIError(error)
        }
    }

    private func signIn(_ request: Memos_Api_SignInRequest) async throws(APIError) -> Memos_Api_User {
        let response = await auth.signIn(request: request, headers: [:])
        switch response.result {
        case .success(let output):
            await session.store(Credentials(
                serverURL: serverURL,
                user: output.user.name,
                accessToken: output.accessToken,
                accessTokenExpiry: output.accessTokenExpireTime.date,
                refreshToken: RefreshCookie.value(in: response.headers),
                dialect: dialect
            ))
            return output.user
        case .failure(let error):
            throw APIError(error)
        }
    }

    /// Revokes the refresh token on the server when it can, and forgets the credentials either way.
    /// An access token used to sign in stays valid; it's managed on the web.
    public func signOut() async {
        if let credentials = await session.credentials, credentials.refreshToken != nil {
            _ = await auth.signOut(request: Memos_Api_SignOutRequest(), headers: Self.headers(
                bearer: credentials.accessToken,
                refreshToken: credentials.refreshToken
            ))
        }
        await session.store(nil)
    }

    static func headers(bearer: String, refreshToken: String? = nil) -> Headers {
        var headers: Headers = ["authorization": ["Bearer \(bearer)"]]
        if let refreshToken {
            headers["cookie"] = [RefreshCookie.header(refreshToken)]
        }
        return headers
    }
}

/// Reads and writes the `memos_refresh` cookie by hand.
enum RefreshCookie {
    static let name = "memos_refresh"

    static func header(_ value: String) -> String { "\(name)=\(value)" }

    /// The cookie's value from `Set-Cookie`, or nil when the response didn't set it. An empty
    /// value means the server cleared it.
    static func value(in headers: Headers) -> String? {
        for line in headers["set-cookie"] ?? [] {
            // URLSession folds several Set-Cookie headers into one comma-separated line.
            guard let range = line.range(of: "\(name)=") else { continue }
            let rest = line[range.upperBound...]
            return String(rest.prefix { $0 != ";" && $0 != "," })
        }
        return nil
    }
}

/// Owns the credentials and serializes refreshes, so concurrent calls that all find an expired
/// token share one refresh instead of rotating the refresh token several times.
actor SessionKeeper {
    private let serverURL: URL
    private let store: CredentialStore
    private let auth: Memos_Api_AuthServiceClient
    private let onSessionExpired: @Sendable () -> Void
    private var inFlightRefresh: Task<String, any Error>?
    private var cached: Credentials?

    /// Refresh this long before the access token's stated expiry, to allow for clock skew.
    private static let expiryMargin: TimeInterval = 60

    init(serverURL: URL, store: CredentialStore, auth: Memos_Api_AuthServiceClient, onSessionExpired: @escaping @Sendable () -> Void) {
        self.serverURL = serverURL
        self.store = store
        self.auth = auth
        self.onSessionExpired = onSessionExpired
        self.cached = store.load()
    }

    var credentials: Credentials? { cached }

    func store(_ credentials: Credentials?) {
        cached = credentials
        store.save(credentials)
    }

    func validAccessToken() async throws(APIError) -> String {
        guard let credentials = cached else { throw .sessionExpired }
        if credentials.accessTokenExpiry.timeIntervalSinceNow > Self.expiryMargin {
            return credentials.accessToken
        }
        return try await refresh(replacing: credentials.accessToken)
    }

    /// Exchanges the refresh cookie for a new access token, unless another call already
    /// replaced `token` while this one was waiting.
    func refresh(replacing token: String) async throws(APIError) -> String {
        if let cached, cached.accessToken != token, cached.accessTokenExpiry.timeIntervalSinceNow > Self.expiryMargin {
            return cached.accessToken
        }
        if let inFlightRefresh {
            return try await Self.value(of: inFlightRefresh)
        }
        let task = Task { try await self.performRefresh() }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await Self.value(of: task)
    }

    private static func value(of task: Task<String, any Error>) async throws(APIError) -> String {
        do {
            return try await task.value
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError(code: .unknown, message: error.localizedDescription)
        }
    }

    private func performRefresh() async throws -> String {
        // An extension may have rotated the refresh token since this process last read it.
        guard var credentials = store.load() ?? cached, let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            expire()
            throw APIError.sessionExpired
        }
        let response = await auth.refreshToken(
            request: Memos_Api_RefreshTokenRequest(),
            headers: ["cookie": [RefreshCookie.header(refreshToken)]]
        )
        switch response.result {
        case .success(let output):
            credentials.accessToken = output.accessToken
            credentials.accessTokenExpiry = output.accessTokenExpireTime.date
            if let rotated = RefreshCookie.value(in: response.headers), !rotated.isEmpty {
                credentials.refreshToken = rotated
            }
            store(credentials)
            return output.accessToken
        case .failure(let error):
            if error.code == .unauthenticated {
                // Another process (the app or an extension) may have rotated the refresh token
                // a moment ago, revoking the one this refresh sent. Try theirs before giving up.
                if let latest = store.load(), let rotated = latest.refreshToken, rotated != refreshToken {
                    cached = latest
                    return try await performRefresh()
                }
                expire(ifStill: refreshToken)
            }
            throw APIError(error)
        }
    }

    /// Signs out, unless another process has stored a newer session in the meantime.
    private func expire(ifStill refreshToken: String? = nil) {
        if let refreshToken, let latest = store.load(), latest.refreshToken != refreshToken {
            cached = latest
            return
        }
        store(nil)
        onSessionExpired()
    }
}
