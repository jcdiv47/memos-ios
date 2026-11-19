import ImageIO
import MemosCore
import SwiftUI

/// Display names and pictures for the people whose memos and comments you see, fetched in
/// batches as they appear and kept for the session. The on-device library has nobody else, and
/// no server to ask.
@Observable
final class PeopleDirectory {
    /// Nil for the on-device library.
    private let client: MemosClient?
    private let store: MemoStore
    private(set) var users: [String: User] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private let avatars = NSCache<NSString, UIImage>()

    init(client: MemosClient?, store: MemoStore) {
        self.client = client
        self.store = store
        avatars.countLimit = 200
    }

    private var me: String { store.user }

    /// What the server says about `user`, yourself included, once known.
    func user(_ user: String) -> User? {
        if user == me { return store.profile.user }
        if let known = users[user] { return known }
        request(user)
        return nil
    }

    /// The display name once known, and the username until then.
    func name(for user: String) -> String {
        self.user(user)?.displayLabel ?? ResourceName.lastSegment(user)
    }

    func request(_ user: String) {
        guard client != nil, !user.isEmpty, user != me, !requested.contains(user) else { return }
        requested.insert(user)
        pending.insert(user)
        guard fetchTask == nil else { return }
        fetchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await self?.fetchPending()
        }
    }

    func remember(_ user: User) {
        users[user.name] = user
    }

    private func fetchPending() async {
        let names = Array(pending)
        pending.removeAll()
        fetchTask = nil
        guard let client, !names.isEmpty else { return }
        var request = Memos_Api_BatchGetUsersRequest()
        request.names = names
        if let response = try? await client.call(client.users.batchGetUsers(request:headers:), request) {
            for user in response.users { users[user.name] = user }
        } else {
            // Try again next time they appear.
            requested.subtract(names)
        }
    }

    // MARK: Avatars

    /// Where `user`'s picture is, or nil if they haven't set one. The server gives an uploaded
    /// picture as a path on its file server, and one from a sign-in provider as a full URL.
    private func avatarURL(for user: String) -> URL? {
        guard let client, let path = self.user(user)?.avatarURL, !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return client.serverURL.appending(path: String(path.dropFirst())) }
        return URL(string: path)
    }

    /// Identifies the current picture. The server keeps the same URL for a new one, so this
    /// includes when the user last changed.
    func avatarKey(for user: String) -> String? {
        guard let url = avatarURL(for: user) else { return nil }
        return "\(url.absoluteString)#\(self.user(user)?.updateTime.seconds ?? 0)"
    }

    func cachedAvatar(for user: String) -> UIImage? {
        avatarKey(for: user).flatMap { avatars.object(forKey: $0 as NSString) }
    }

    func avatar(for user: String) async -> UIImage? {
        guard let url = avatarURL(for: user), let key = avatarKey(for: user) as NSString? else { return nil }
        if let cached = avatars.object(forKey: key) { return cached }
        var request = URLRequest(url: url)
        if let client, url.host() == client.serverURL.host() {
            guard let authorized = try? await client.authorizedRequest(for: url) else { return nil }
            request = authorized
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let image = await Self.decode(data)
        else { return nil }
        avatars.setObject(image, forKey: key)
        return image
    }

    @concurrent
    private static func decode(_ data: Data) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 192,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// A person's picture from the server, or their initial while it loads or if they have none.
struct UserAvatar: View {
    let user: String
    var size: CGFloat = 28

    @Environment(AccountSession.self) private var session
    @State private var image: UIImage?
    /// Grows with the name beside it, so a large name doesn't dwarf its avatar.
    @ScaledMetric(relativeTo: .subheadline) private var scale = SymbolScale.base

    var body: some View {
        let people = session.people
        let size = Metrics.scaled(self.size, by: scale)
        Group {
            if let image = image ?? people.cachedAvatar(for: user) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.circle)
                    .accessibilityHidden(true)
            } else {
                Avatar(name: people.name(for: user), size: size)
            }
        }
        .task(id: people.avatarKey(for: user)) {
            image = await people.avatar(for: user)
        }
    }
}
