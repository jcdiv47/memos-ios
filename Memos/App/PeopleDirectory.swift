import MemosCore
import SwiftUI

/// Display names for the people whose memos and comments you see, fetched in batches as they
/// appear and kept for the session.
@Observable
final class PeopleDirectory {
    private let client: MemosClient
    private let me: String
    private(set) var users: [String: User] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var fetchTask: Task<Void, Never>?

    init(client: MemosClient, me: String) {
        self.client = client
        self.me = me
    }

    /// “You” for yourself, otherwise the display name once known and the username until then.
    func name(for user: String) -> String {
        if user == me { return String(localized: "You", comment: "Stands in for your own name as the author of a memo or comment.") }
        if let known = users[user] { return known.displayLabel }
        request(user)
        return ResourceName.lastSegment(user)
    }

    func request(_ user: String) {
        guard !user.isEmpty, user != me, !requested.contains(user) else { return }
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
        guard !names.isEmpty else { return }
        var request = Memos_Api_BatchGetUsersRequest()
        request.names = names
        if let response = try? await client.call(client.users.batchGetUsers(request:headers:), request) {
            for user in response.users { users[user.name] = user }
        } else {
            // Try again next time they appear.
            requested.subtract(names)
        }
    }
}
