import MemosCore
import SwiftUI
import WidgetKit

/// The root of the app: which library is open, if any — a server account or the on-device
/// library — and its session.
///
/// The two are independent. Each keeps its own local copy, and only one is open at a time.
/// Switching to the on-device library keeps you signed in to the server, with its queue waiting
/// until you switch back; signing out erases only the server's copy, and erasing the on-device
/// library leaves the server account alone.
@Observable
final class AppModel {
    /// One per process: the app's scenes and its intents share it.
    static let shared = AppModel()

    enum Phase {
        case launching
        /// Neither library is open: the sign-in screen, which also offers the on-device library.
        case signedOut
        case open(AccountSession)
    }

    private(set) var phase: Phase = .launching
    /// Set when the refresh token was rejected. The local copy stays; signing in again resumes it.
    var sessionExpired = false

    private let credentialStore: CredentialStore = KeychainCredentialStore()

    var session: AccountSession? {
        if case .open(let session) = phase { session } else { nil }
    }

    @ObservationIgnored private var restoring: Task<Void, Never>?

    /// The server account you're signed in to, whether or not it's open right now.
    var serverAccount: (url: URL, user: String)? {
        credentialStore.load().map { ($0.serverURL, $0.user) }
    }

    /// Whether there is an on-device library to go back to, for the sign-in screen.
    var hasOnDeviceLibrary: Bool {
        AccountLocation.hasOnDeviceLibrary(in: SharedContainer.directory)
    }

    /// Picks up where the last launch left off: the library that was open, and its local copy.
    /// Safe to call more than once; later calls wait for the first.
    func restore() async {
        guard case .launching = phase else { return }
        if let restoring { return await restoring.value }
        let task = Task {
            #if DEBUG
            await signInFromEnvironment()
            #endif
            if AccountLocation.isOnDeviceCurrent {
                await openOnDevice()
                return
            }
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
    /// without the form. `MEMOS_DEV_ON_DEVICE=1` opens the on-device library instead.
    private func signInFromEnvironment() async {
        let environment = ProcessInfo.processInfo.environment
        if environment["MEMOS_DEV_RESET"] == "1" {
            if let existing = credentialStore.load() {
                let location = AccountLocation(container: SharedContainer.directory, serverURL: existing.serverURL, user: existing.user)
                await AccountArchive.erase(location)
                credentialStore.save(nil)
                AccountLocation.forgetServer()
            }
            await AccountArchive.erase(.onDevice(container: SharedContainer.directory))
            AccountLocation.forgetOnDevice()
        }
        if environment["MEMOS_DEV_ON_DEVICE"] == "1" {
            AccountLocation.recordCurrentOnDevice()
            return
        }
        guard let server = environment["MEMOS_DEV_SERVER"].flatMap(MemosClient.normalizedServerURL) else { return }
        AccountLocation.forgetOnDevice()
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
        if let session, session.client?.serverURL == serverURL, session.store.user == user.name {
            await session.engine?.sync()
            return
        }
        await start(serverURL: serverURL, user: user.name)
    }

    private func start(serverURL: URL, user: String) async {
        await closeSession()
        let session = AccountSession(client: makeClient(for: serverURL), user: user)
        AccountLocation.recordCurrent(serverURL: serverURL, user: user)
        await open(session)
    }

    /// Opens the on-device library, creating it the first time. A server account stays signed in.
    func openOnDevice() async {
        if session?.isOnDevice == true { return }
        await closeSession()
        sessionExpired = false
        let session = AccountSession(onDeviceIn: SharedContainer.directory)
        AccountLocation.recordCurrentOnDevice()
        await open(session)
    }

    /// Goes back from the on-device library to the server account you're still signed in to.
    func openServerAccount() async {
        guard let credentials = credentialStore.load() else { return }
        await start(serverURL: credentials.serverURL, user: credentials.user)
    }

    private func open(_ session: AccountSession) async {
        await session.start()
        phase = .open(session)
        // Spotlight and the widgets show the library that's open, not the one before.
        SpotlightIndex.replace(with: session.store)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Saves the open library and lets it go, leaving its local copy as it is.
    private func closeSession() async {
        guard let session else { return }
        await session.stop()
    }

    /// Deletes the server account's local copy and queue, and revokes the session on the server.
    /// The on-device library is left as it is.
    func signOut() async {
        guard let session, let client = session.client else { return }
        await session.stop()
        await client.signOut()
        // First, so no pending draft write lands after the folder is gone.
        session.drafts.removeAll()
        await AccountArchive.erase(session.store.location)
        AccountLocation.forgetServer()
        sessionExpired = false
        phase = .signedOut
        SpotlightIndex.clear()
        // Otherwise widgets keep showing the erased memos until their next scheduled refresh.
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Deletes every memo and file in the on-device library. Opens the server account if you're
    /// signed in to one, and the sign-in screen otherwise.
    func eraseOnDevice() async {
        guard let session, session.isOnDevice else { return }
        await session.stop()
        session.drafts.removeAll()
        await AccountArchive.erase(session.store.location)
        AccountLocation.forgetOnDevice()
        SpotlightIndex.clear()
        if credentialStore.load() != nil {
            await openServerAccount()
        } else {
            phase = .signedOut
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
