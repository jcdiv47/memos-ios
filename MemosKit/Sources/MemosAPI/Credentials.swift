import Foundation
import Synchronization

/// What it takes to talk to one instance as one user. Persisted by a ``CredentialStore``.
public struct Credentials: Codable, Sendable, Equatable {
    public var serverURL: URL
    /// Resource name of the signed-in user, `users/{username}`.
    public var user: String
    public var accessToken: String
    public var accessTokenExpiry: Date
    /// Value of the `memos_refresh` cookie. The server rotates it on every refresh.
    public var refreshToken: String?
    /// The API the server speaks. Nil in credentials saved before the app knew about 0.31.
    public var dialect: ServerDialect?

    public init(
        serverURL: URL,
        user: String,
        accessToken: String,
        accessTokenExpiry: Date,
        refreshToken: String?,
        dialect: ServerDialect? = nil
    ) {
        self.serverURL = serverURL
        self.user = user
        self.accessToken = accessToken
        self.accessTokenExpiry = accessTokenExpiry
        self.refreshToken = refreshToken
        self.dialect = dialect
    }
}

/// Persists ``Credentials``. The app uses the Keychain; tests use ``InMemoryCredentialStore``.
public protocol CredentialStore: Sendable {
    func load() -> Credentials?
    func save(_ credentials: Credentials?)
}

public final class InMemoryCredentialStore: CredentialStore {
    private let storage: Mutex<Credentials?>

    public init(_ credentials: Credentials? = nil) {
        storage = Mutex(credentials)
    }

    public func load() -> Credentials? { storage.withLock { $0 } }
    public func save(_ credentials: Credentials?) { storage.withLock { $0 = credentials } }
}
