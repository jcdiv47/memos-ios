import Foundation
import Security

/// Keeps ``Credentials`` in the Keychain, in an access group the app shares with its widgets and
/// share extension. Falls back to the app's own Keychain when the group isn't entitled (an
/// unsigned simulator build).
public final class KeychainCredentialStore: CredentialStore {
    private let service: String
    private let accessGroup: String?
    private static let account = "session"

    public init(service: String = "app.memos.session", accessGroup: String? = SharedContainer.keychainAccessGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func load() -> Credentials? {
        for group in groups {
            var query = baseQuery(group: group)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data,
               let credentials = try? JSONDecoder().decode(Credentials.self, from: data) {
                return credentials
            }
        }
        return nil
    }

    public func save(_ credentials: Credentials?) {
        for group in groups {
            SecItemDelete(baseQuery(group: group) as CFDictionary)
        }
        guard let credentials, let data = try? JSONEncoder().encode(credentials) else { return }
        for group in groups {
            var item = baseQuery(group: group)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if SecItemAdd(item as CFDictionary, nil) == errSecSuccess { return }
        }
    }

    private var groups: [String?] {
        accessGroup.map { [$0, nil] } ?? [nil]
    }

    private func baseQuery(group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }
}

/// Locations shared by the app and its extensions.
public enum SharedContainer {
    /// From Info.plist (`MemosAppGroup`), which every target sets from the same build setting.
    public static var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "MemosAppGroup") as? String ?? "group.app.memos"
    }

    /// From Info.plist (`MemosKeychainGroup`), which carries the team prefix.
    public static var keychainAccessGroup: String? {
        (Bundle.main.object(forInfoDictionaryKey: "MemosKeychainGroup") as? String).flatMap { $0.hasPrefix("$(") ? nil : $0 }
    }

    /// The app group container, or Application Support when the group isn't entitled.
    public static var directory: URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return group
        }
        let support = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    /// Settings shared with the extensions: which account is signed in.
    public static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }
}
