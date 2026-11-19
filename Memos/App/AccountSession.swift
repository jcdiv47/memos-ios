import MemosCore
import SwiftUI
import WidgetKit

/// Everything for the signed-in account: the client, the local copy, sync, and the app-wide
/// navigation and presentation state.
@Observable
final class AccountSession {
    let client: MemosClient
    let store: MemoStore
    let engine: SyncEngine
    let connectivity = Connectivity()
    let files: AttachmentFiles
    /// Finding photos by describing them, once MobileCLIP is downloaded.
    let photoSearch: PhotoSearchModel
    let people: PeopleDirectory
    let voice = VoiceRecorder()
    /// The composer's unsaved work.
    let drafts: DraftStore

    /// The timeline's navigation stack.
    var path: [Route] = []
    /// The composer, when one is open.
    var composer: ComposerRequest?
    var isInboxPresented = false
    var isSettingsPresented = false
    /// The Voice memo control's recorder, which saves without a composer.
    var isQuickVoiceMemoPresented = false
    /// Set by deep links and the search intent; the timeline opens search with it.
    var pendingSearch: SearchQuery?
    /// Memos with a blurred tag you've shown, so the card and its detail agree. Forgotten on
    /// relaunch, as the web forgets on reload.
    var revealedMemos: Set<String> = []

    /// Mine or Everyone, from the title menu. Persisted per account.
    var scope: MemoQuery.Scope {
        didSet { UserDefaults.standard.set(scope == .everyone, forKey: preferenceKey("timeline.everyone")) }
    }

    /// The Space chosen in the title menu, or nil for All Spaces. Persisted per account; new
    /// memos default to it.
    var selectedSpace: String? {
        didSet { UserDefaults.standard.set(selectedSpace, forKey: preferenceKey("timeline.space")) }
    }

    /// Timeline preferences are kept per account: a Space on one server means nothing on another.
    @ObservationIgnored private let preferencePrefix: String

    private func preferenceKey(_ name: String) -> String { "\(name).\(preferencePrefix)" }

    /// A quick filter from the toolbar's filter menu.
    var quickFilter: SearchToken?

    /// Link previews fetched this session, by URL.
    @ObservationIgnored var linkPreviews: [String: Memos_Api_LinkMetadata] = [:]

    init(client: MemosClient, user: String) {
        self.client = client
        let location = AccountLocation(container: SharedContainer.directory, serverURL: client.serverURL, user: user)
        store = MemoStore(location: location)
        drafts = DraftStore(directory: location.draftsDirectory)
        engine = SyncEngine(client: client, store: store)
        files = AttachmentFiles(client: client, store: store)
        photoSearch = PhotoSearchModel(store: store, files: files)
        people = PeopleDirectory(client: client, store: store)
        preferencePrefix = "\(client.serverURL.absoluteString)|\(user)"
        scope = UserDefaults.standard.bool(forKey: "timeline.everyone.\(preferencePrefix)") ? .everyone : .mine
        selectedSpace = UserDefaults.standard.string(forKey: "timeline.space.\(preferencePrefix)")
    }

    var user: String { store.user }

    @ObservationIgnored private var queryCache: [(query: MemoQuery, revision: Int, memos: [Memo])] = []

    /// ``MemoStore/memos(_:now:)``, cached until the store changes, since timelines ask for the
    /// same list on every render.
    func memos(_ query: MemoQuery) -> [Memo] {
        let revision = store.revision
        if let hit = queryCache.first(where: { $0.query == query && $0.revision == revision }) {
            return hit.memos
        }
        let memos = store.memos(query)
        queryCache.removeAll { $0.revision != revision || $0.query == query }
        queryCache.append((query, revision, memos))
        if queryCache.count > 8 { queryCache.removeFirst() }
        return memos
    }
    /// Offline means no network, or a server that isn't answering.
    var isOnline: Bool { connectivity.isOnline && engine.isOnline }

    /// The Mine / Everyone toggle appears only when someone else's memos are readable to you.
    var showsScopeToggle: Bool { store.profile.hasOtherCreators }

    /// The effective scope: Everyone falls back to Mine when nobody else shares.
    var effectiveScope: MemoQuery.Scope { showsScopeToggle ? scope : .mine }

    /// A Space that no longer exists, or that the profile doesn't list once it has loaded, falls
    /// back to All Spaces.
    private func dropMissingSpace() {
        guard let selectedSpace, store.profile.user != nil, space(named: selectedSpace) == nil else { return }
        self.selectedSpace = nil
    }

    var selectedSpaceTitle: String {
        guard let selectedSpace else { return String(localized: "All Spaces") }
        return store.profile.spaces.first { $0.name == selectedSpace }?.title ?? String(localized: "Space")
    }

    func space(named name: String?) -> Space? {
        guard let name else { return nil }
        return store.profile.spaces.first { $0.name == name }
    }

    func start() async {
        await store.load()
        ExtensionInbox.drain(into: store)
        connectivity.onChange = { [weak self] online, expensive in
            guard let self else { return }
            self.engine.isExpensiveNetwork = expensive
            self.engine.isOnline = online
            if online {
                Task {
                    await self.engine.sync()
                    self.photoSearch.indexIfNeeded()
                }
            }
        }
        connectivity.start()
        dropMissingSpace()
        Task {
            await engine.sync()
            dropMissingSpace()
            files.prefetchThumbnails()
            photoSearch.indexIfNeeded()
            SpotlightIndex.update(store)
        }
        #if DEBUG
        // For checking sync by hand: `MEMOS_DEV_CREATE` writes a memo at launch.
        if let text = ProcessInfo.processInfo.environment["MEMOS_DEV_CREATE"], !text.isEmpty {
            store.create(MemoDraft(content: text, visibility: .private))
        }
        // For screenshots: `MEMOS_DEV_OPEN` holds space-separated memos:// links to open.
        for link in (ProcessInfo.processInfo.environment["MEMOS_DEV_OPEN"] ?? "").split(separator: " ") {
            if let url = URL(string: String(link)) { open(url) }
        }
        #endif
    }

    func stop() async {
        connectivity.stop()
        await photoSearch.stop()
        drafts.flush()
        await store.save()
    }

    /// Foreground: import what extensions left, then sync.
    func didBecomeActive() async {
        ExtensionInbox.drain(into: store)
        if connectivity.isOnline { engine.isOnline = true }
        await engine.sync()
        files.prefetchThumbnails()
        photoSearch.refresh()
        photoSearch.indexIfNeeded()
    }

    func didEnterBackground() async {
        // Ask for time to finish writing the local copy and the queue before suspension.
        let task = UIApplication.shared.beginBackgroundTask(withName: "Save memos")
        defer { UIApplication.shared.endBackgroundTask(task) }
        drafts.flush()
        await store.save()
        await SpotlightIndex.reindex(store)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Capture

    /// Opens the composer as the capture field would: in the current Space, with the visibility
    /// rules applied.
    func capture(text: String = "", record: Bool = false, origin: CaptureOrigin? = nil) {
        composer = ComposerRequest(mode: .new(origin: origin ?? .timeline(space: selectedSpace), text: text, record: record))
    }

    func edit(_ name: String) {
        composer = ComposerRequest(mode: .edit(name))
    }

    var defaultVisibility: MemoVisibility? {
        store.profile.defaultVisibility.flatMap(MemoVisibility.init(filterValue:))
    }

    // MARK: Links

    /// `memos://new`, `memos://voice`, `memos://memo/{uid}`, `memos://search?q=…`, and links to
    /// this instance's memos.
    func open(_ url: URL) {
        if url.scheme == "memos" {
            let parts = url.pathComponents.filter { $0 != "/" }
            switch url.host() {
            case "new":
                capture(text: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value ?? "",
                        origin: .shareSheet)
            case "capture":
                // Exactly what tapping the capture field does: the current Space and its rules.
                capture()
            case "voice":
                capture(record: true)
            case "memo":
                if let uid = parts.first { show(memo: "memos/\(uid)") }
            case "search":
                let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
                pendingSearch = SearchQuery(text: text)
            case "inbox":
                isInboxPresented = true
            case "library":
                path = [.library] + (parts.first.flatMap(Self.libraryRoute).map { [$0] } ?? [])
            case "settings":
                isSettingsPresented = true
            case "space":
                selectedSpace = parts.first.map { "spaces/\($0)" }
            case "scope":
                scope = parts.first == "everyone" ? .everyone : .mine
            default:
                break
            }
            return
        }
        // https://instance/memos/{uid} and /memos/shares/{token}
        guard url.host() == client.serverURL.host() else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count == 3, parts[0] == "memos", parts[1] == "shares" {
            path.append(.sharedMemo(token: parts[2]))
        } else if parts.count == 2, parts[0] == "memos" {
            show(memo: "memos/\(parts[1])")
        }
    }

    private static func libraryRoute(_ name: String) -> Route? {
        switch name {
        case "activity": .activity
        case "attachments": .attachments
        case "map": .map
        case "tags": .tags
        case "archived": .archived
        default: nil
        }
    }

    func show(memo name: String) {
        composer = nil
        isInboxPresented = false
        path.append(.memo(name))
    }

    /// The web address of a memo on this instance.
    func webURL(for memo: Memo) -> URL {
        client.serverURL.appending(path: memo.name)
    }
}

/// Screens pushed onto the timeline's stack.
enum Route: Hashable {
    case memo(String)
    case sharedMemo(token: String)
    case library
    case activity
    case attachments
    case map
    case tags
    case archived
    case view(String)
    case filtered(title: String, tokens: [SearchToken])
}

/// What the composer opens for.
struct ComposerRequest: Identifiable {
    enum Mode {
        /// A new memo. `record` starts a voice memo right away; `voiceMemo` takes over a
        /// recording that the capture field already stopped.
        case new(origin: CaptureOrigin, text: String, record: Bool, voiceMemo: Bool = false)
        case edit(String)
    }

    let id = UUID()
    var mode: Mode
}
