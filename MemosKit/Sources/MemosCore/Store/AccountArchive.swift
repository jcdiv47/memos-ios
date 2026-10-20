import Foundation
import SwiftProtobuf

/// Where one account's local copy lives: `<container>/Accounts/<host>-<user>/`. The container is
/// the shared app group when available, so widgets and the share extension read the same copy.
public struct AccountLocation: Sendable, Equatable {
    public let directory: URL
    public let user: String

    public init(container: URL, serverURL: URL, user: String) {
        let host = (serverURL.host() ?? "server") + (serverURL.port.map { "-\($0)" } ?? "") + serverURL.path().replacingOccurrences(of: "/", with: "-")
        let folder = "\(host)-\(ResourceName.lastSegment(user))".filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        self.directory = container.appending(path: "Accounts", directoryHint: .isDirectory).appending(path: folder, directoryHint: .isDirectory)
        self.user = user
    }

    /// The signed-in account, as the app last recorded it in the shared defaults. Extensions
    /// use this to find the local copy.
    public static var current: AccountLocation? {
        let defaults = SharedContainer.defaults
        guard let server = defaults.string(forKey: "serverURL").flatMap(URL.init(string:)),
              let user = defaults.string(forKey: "user")
        else { return nil }
        return AccountLocation(container: SharedContainer.directory, serverURL: server, user: user)
    }

    /// The server the account belongs to.
    public static var currentServer: URL? {
        SharedContainer.defaults.string(forKey: "serverURL").flatMap(URL.init(string:))
    }

    var ownMemosFile: URL { directory.appending(path: "own.binpb") }
    var otherMemosFile: URL { directory.appending(path: "others.binpb") }
    var stateFile: URL { directory.appending(path: "state.json") }
    var profileFile: URL { directory.appending(path: "profile.json") }
    /// Files waiting to upload, named by attachment UID.
    public var uploadsDirectory: URL { directory.appending(path: "Uploads", directoryHint: .isDirectory) }
    /// Downloaded thumbnails and full-size files.
    public var filesDirectory: URL { directory.appending(path: "Files", directoryHint: .isDirectory) }
    /// Drop-off for memos saved by extensions while the app wasn't running.
    public var inboxDirectory: URL { directory.appending(path: "Inbox", directoryHint: .isDirectory) }
    /// The composer's unsaved drafts.
    public var draftsDirectory: URL { directory.appending(path: "Drafts", directoryHint: .isDirectory) }

    public func uploadFile(for attachment: String) -> URL {
        uploadsDirectory.appending(path: ResourceName.lastSegment(attachment))
    }
}

/// Sync bookkeeping, persisted with the memos.
public struct SyncState: Codable, Equatable, Sendable {
    /// The newest `update_time` seen from the server. The next change fetch starts one second
    /// before it, because the server stores seconds.
    public var cursor: Date?
    public var lastSyncAt: Date?
    public var lastFullCompareAt: Date?
    public var outbox: [PendingChange] = []
    /// Memo pairs split by a text conflict: each memo maps to its counterpart.
    public var conflicts: [String: String] = [:]
    /// When other people's memos were last fetched, for “Updated 2 hours ago” offline.
    public var othersFetchedAt: Date?

    public init() {}
}

/// Everything about the account besides memos that the app shows offline.
public struct ProfileCache: Codable, Equatable, Sendable {
    @ProtoValue public var user: User?
    @ProtoValue public var instance: Memos_Api_InstanceProfile?
    @ProtoValues public var spaces: [Space]
    @ProtoValues public var views: [MemoView]
    /// The `memo_visibility` setting. Nil when never set.
    public var defaultVisibility: String?
    /// Whether someone else's memos are readable, which is what shows the Mine / Everyone toggle.
    public var hasOtherCreators = false
    /// The instance's reaction set, or empty for the built-in one.
    public var reactions: [String] = []
    public var unreadNotifications = 0
    /// Memo counts per tag across your memos, from the server.
    public var tagCounts: [String: Int] = [:]
    /// The `TAGS` setting's blur rules. Optional so profiles saved before it still decode.
    public var tagBlur: TagBlurRules?

    public var tagBlurRules: TagBlurRules { tagBlur ?? TagBlurRules() }

    public init() {
        _user = ProtoValue(nil)
        _instance = ProtoValue(nil)
        _spaces = ProtoValues([])
        _views = ProtoValues([])
    }

    public static let defaultReactions = ["👍", "❤️", "💡", "🎉", "👀", "😂", "🙏", "🌱"]

    public var reactionChoices: [String] { reactions.isEmpty ? Self.defaultReactions : reactions }
}

/// Stores a protobuf message inside a `Codable` value as its binary encoding.
@propertyWrapper
public struct ProtoValue<M: SwiftProtobuf.Message & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var wrappedValue: M?

    public init(_ wrappedValue: M?) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: M?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else {
            wrappedValue = try M(serializedBytes: try container.decode(Data.self))
        }
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(try wrappedValue.serializedBytes() as Data)
        } else {
            try container.encodeNil()
        }
    }
}

@propertyWrapper
public struct ProtoValues<M: SwiftProtobuf.Message & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var wrappedValue: [M]

    public init(_ wrappedValue: [M]) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: [M]) { self.wrappedValue = wrappedValue }

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = try container.decode([Data].self).map { try M(serializedBytes: $0) }
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(try wrappedValue.map { try $0.serializedBytes() as Data })
    }
}

/// Everything persisted for an account, read and written as a unit off the main actor.
public struct AccountSnapshot: Sendable {
    public var own: [Memo] = []
    public var others: [Memo] = []
    public var state = SyncState()
    public var profile = ProfileCache()

    public init() {}
}

public enum AccountArchive {
    @concurrent
    public static func read(_ location: AccountLocation) async -> AccountSnapshot {
        var snapshot = AccountSnapshot()
        snapshot.own = readMemos(location.ownMemosFile)
        snapshot.others = readMemos(location.otherMemosFile)
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: location.stateFile), let state = try? decoder.decode(SyncState.self, from: data) {
            snapshot.state = state
        }
        if let data = try? Data(contentsOf: location.profileFile), let profile = try? decoder.decode(ProfileCache.self, from: data) {
            snapshot.profile = profile
        }
        return snapshot
    }

    /// Just the profile, for extensions that need the default visibility or the Spaces.
    @concurrent
    public static func readProfile(_ location: AccountLocation) async -> ProfileCache {
        guard let data = try? Data(contentsOf: location.profileFile),
              let profile = try? JSONDecoder().decode(ProfileCache.self, from: data)
        else { return ProfileCache() }
        return profile
    }

    /// Your memos only, for widgets.
    @concurrent
    public static func readOwnMemos(_ location: AccountLocation) async -> [Memo] {
        readMemos(location.ownMemosFile)
    }

    /// Writes whichever parts are given, each atomically.
    @concurrent
    public static func write(
        _ location: AccountLocation,
        own: [Memo]? = nil,
        others: [Memo]? = nil,
        state: SyncState? = nil,
        profile: ProfileCache? = nil
    ) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: location.directory, withIntermediateDirectories: true)
        if let own {
            try writeMemos(own, to: location.ownMemosFile)
        }
        if let others {
            try writeMemos(others, to: location.otherMemosFile)
        }
        let encoder = JSONEncoder()
        if let state {
            try encoder.encode(state).write(to: location.stateFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        if let profile {
            try encoder.encode(profile).write(to: location.profileFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Deletes the local copy, the queue and every cached file.
    @concurrent
    public static func erase(_ location: AccountLocation) async {
        try? FileManager.default.removeItem(at: location.directory)
    }

    private static func readMemos(_ url: URL) -> [Memo] {
        guard let data = try? Data(contentsOf: url),
              let container = try? Memos_Api_ListMemosResponse(serializedBytes: data)
        else { return [] }
        return container.memos
    }

    private static func writeMemos(_ memos: [Memo], to url: URL) throws {
        var container = Memos_Api_ListMemosResponse()
        container.memos = memos
        let data: Data = try container.serializedBytes()
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
