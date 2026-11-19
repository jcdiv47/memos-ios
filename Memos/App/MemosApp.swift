import MemosCore
import SwiftUI

@main
struct MemosApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppAppearance.apply()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.restore() }
                .onOpenURL { url in model.session?.open(url) }
                .onChange(of: scenePhase) { _, phase in
                    guard let session = model.session else { return }
                    switch phase {
                    case .active: Task { await session.didBecomeActive() }
                    case .background: Task { await session.didEnterBackground() }
                    default: break
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .launching:
                Color.paper.ignoresSafeArea()
            case .signedOut:
                SignInView()
            case .signedIn(let session):
                Group {
                    if sizeClass == .regular {
                        SplitRootView()
                    } else {
                        TimelineScreen()
                    }
                }
                .environment(session)
                .sheet(isPresented: $model.sessionExpired) {
                    SignInView(resuming: session.client.serverURL)
                        .interactiveDismissDisabled()
                }
            }
        }
        .tint(.memosBlue)
    }
}

/// UIKit appearance the SwiftUI modifiers don't reach: the large title in New York.
enum AppAppearance {
    static func apply() {
        let serif = UIFont.systemFont(ofSize: 34, weight: .bold).fontDescriptor.withDesign(.serif)
            .map { UIFont(descriptor: $0, size: 34) } ?? .systemFont(ofSize: 34, weight: .bold)
        let metrics = UIFontMetrics(forTextStyle: .largeTitle)
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: metrics.scaledFont(for: serif)]
        let inline = UIFont.systemFont(ofSize: 17, weight: .semibold).fontDescriptor.withDesign(.serif)
            .map { UIFont(descriptor: $0, size: 17) } ?? .systemFont(ofSize: 17, weight: .semibold)
        UINavigationBar.appearance().titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline)]
    }
}
