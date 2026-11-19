import UIKit

/// The Home Screen icon's long-press menu, declared under `UIApplicationShortcutItems` in
/// Info.plist. SwiftUI has no hook for these, so a scene delegate takes them.
enum HomeScreenAction: String {
    case newMemo = "new-memo"

    init?(_ item: UIApplicationShortcutItem) {
        guard let suffix = item.type.split(separator: ".").last else { return nil }
        self.init(rawValue: String(suffix))
    }

    /// Works on a cold launch too: waits for the account to restore, as the intents do.
    @MainActor
    func perform() {
        Task {
            let model = AppModel.shared
            await model.restore()
            guard let session = model.session else { return }
            switch self {
            case .newMemo:
                // As the New Memo widget does: your default visibility and no Space.
                session.capture(origin: .shareSheet)
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = HomeScreenSceneDelegate.self
        return configuration
    }
}

final class HomeScreenSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold launch from the menu.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem { HomeScreenAction(item)?.perform() }
    }

    /// The app was already running.
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard let action = HomeScreenAction(shortcutItem) else { return completionHandler(false) }
        action.perform()
        completionHandler(true)
    }
}
