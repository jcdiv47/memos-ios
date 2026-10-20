import MemosCore
import SwiftUI
import WidgetKit

/// The root of the app: whether someone is signed in, and the session when they are.
@Observable
final class AppModel {
    /// One per process: the app's scenes and its intents share it.
    static let shared = AppModel()

    enum Phase {
        case launching
        case signedOut
        case signedIn(AccountSession)
    }

    private(set) var phase: Phase = .launching
    /// Set when the refresh token was rejected. The local copy stays; signing in again resumes it.
    var sessionExpired = false

    private let credentialStore: CredentialStore = KeychainCredentialStore()

    var session: AccountSession? {
        if case .signedIn(let session) = phase { session } else { nil }
    }

    @ObservationIgnored private var restoring: Task<Void, Never>?

    /// Picks up where the last launch left off: the stored credentials and the local copy.
    /// Safe to call more than once; later calls wait for the first.
    func restore() async {
        guard case .launching = phase else { return }
        if let restoring { return await restoring.value }
        let task = Task {
            #if DEBUG
            await signInFromEnvironment()
            #endif
            guard let credentials = credentialStore.load() else {
                phase = .signedOut
                return
            }
            await start(serverURL: credentials.serverURL, user: credentials.user)
        }
        restoring = task
        await task.value
    }

    #if DEBUG
    /// For screenshots and UI tests: `MEMOS_DEV_SERVER` with `MEMOS_DEV_USER` and
    /// `MEMOS_DEV_PASSWORD`, or with `MEMOS_DEV_TOKEN`, in the launch environment sign in
    /// without the form.
    private func signInFromEnvironment() async {
        let environment = ProcessInfo.processInfo.environment
        if environment["MEMOS_DEV_RESET"] == "1", let existing = credentialStore.load() {
            let location = AccountLocation(container: SharedContainer.directory, serverURL: existing.serverURL, user: existing.user)
            await AccountArchive.erase(location)
            credentialStore.save(nil)
        }
        guard let server = environment["MEMOS_DEV_SERVER"].flatMap(MemosClient.normalizedServerURL) else { return }
        if let token = environment["MEMOS_DEV_TOKEN"], credentialStore.load() == nil {
            let client = makeClient(for: server)
            _ = try? await client.detectDialect()
            _ = try? await client.signIn(accessToken: token)
            return
        }
        guard let username = environment["MEMOS_DEV_USER"], let password = environment["MEMOS_DEV_PASSWORD"] else { return }
        if let existing = credentialStore.load(), existing.serverURL == server, existing.user == ResourceName.user(username) { return }
        let client = makeClient(for: server)
        _ = try? await client.detectDialect()
        _ = try? await client.signIn(username: username, password: password)
    }
    #endif

    /// Makes a client for an instance before anyone has signed in, to read its profile and
    /// sign-in methods.
    func makeClient(for serverURL: URL) -> MemosClient {
        MemosClient(serverURL: serverURL, credentialStore: credentialStore) { [weak self] in
            Task { @MainActor in self?.sessionExpired = true }
        }
    }

    /// Called once the client has signed in and stored its credentials.
    func didSignIn(serverURL: URL, user: User) async {
        sessionExpired = false
        if let session, session.client.serverURL == serverURL, session.store.user == user.name {
            await session.engine.sync()
            return
        }
        await start(serverURL: serverURL, user: user.name)
    }

    private func start(serverURL: URL, user: String) async {
        let session = AccountSession(client: makeClient(for: serverURL), user: user)
        SharedContainer.defaults.set(serverURL.absoluteString, forKey: "serverURL")
        SharedContainer.defaults.set(user, forKey: "user")
        await session.start()
        phase = .signedIn(session)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Deletes the local copy and the queue, and revokes the session on the server.
    func signOut() async {
        guard let session else { return }
        await session.stop()
        await session.client.signOut()
        await AccountArchive.erase(session.store.location)
        SharedContainer.defaults.removeObject(forKey: "serverURL")
        SharedContainer.defaults.removeObject(forKey: "user")
        sessionExpired = false
        phase = .signedOut
        // Otherwise widgets keep showing the erased memos until their next scheduled refresh.
        WidgetCenter.shared.reloadAllTimelines()
    }
}
