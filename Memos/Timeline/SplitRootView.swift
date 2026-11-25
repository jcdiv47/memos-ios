import MemosCore
import SwiftUI

/// iPad: a split view whose sidebar holds Memos, Spaces, the Library sections and saved views.
/// The timeline fills the detail column.
struct SplitRootView: View {
    @Environment(AccountSession.self) private var session
    @State private var selection: SidebarItem? = .timeline
    @Namespace private var zoom

    enum SidebarItem: Hashable {
        case timeline
        case space(String)
        case route(Route)
    }

    var body: some View {
        @Bindable var session = session
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Memos", icon: .notepadText).tag(SidebarItem.timeline)
                }
                if !session.store.profile.spaces.isEmpty {
                    Section("Spaces") {
                        ForEach(session.store.profile.spaces, id: \.name) { space in
                            Label(space.title, icon: .squareStack).tag(SidebarItem.space(space.name))
                        }
                    }
                }
                Section("Library") {
                    Label("Activity", icon: .calendar).tag(SidebarItem.route(.activity))
                    Label("Attachments", icon: .paperclip).tag(SidebarItem.route(.attachments))
                    Label("Map", icon: .map).tag(SidebarItem.route(.map))
                    Label("Tags", icon: .hash).tag(SidebarItem.route(.tags))
                    Label("Archived", icon: .archive).tag(SidebarItem.route(.archived))
                }
                if !session.store.profile.views.isEmpty {
                    Section("Saved views") {
                        ForEach(session.store.profile.views, id: \.name) { view in
                            Label {
                                Text(view.displayTitle)
                            } icon: {
                                Text(view.emoji ?? "🔖")
                            }
                            .tag(SidebarItem.route(.view(view.name)))
                        }
                    }
                }
            }
            .navigationTitle("Memos")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", icon: .settings) {
                        session.accountSheetSource = SheetSource.sidebarSettings
                        session.isSettingsPresented = true
                    }
                }
                .matchedTransitionSource(id: SheetSource.sidebarSettings, in: zoom)
            }
        } detail: {
            switch selection {
            case .route(let route):
                NavigationStack(path: $session.path) {
                    RouteDestination(route: route, zoom: zoom)
                        .navigationDestination(for: Route.self) { RouteDestination(route: $0, zoom: zoom) }
                }
            default:
                TimelineScreen(presentsSheets: false, sharedZoom: zoom)
            }
        }
        .onChange(of: selection) { _, item in
            session.path = []
            switch item {
            case .timeline: session.selectedSpace = nil
            case .space(let name): session.selectedSpace = name
            default: break
            }
        }
        .sheet(item: $session.composer) { request in
            ComposerView(request: request)
                .zoomTransition(from: request.source, in: zoom)
        }
        .sheet(isPresented: $session.isInboxPresented) {
            InboxView()
                .zoomTransition(from: session.accountSheetSource, in: zoom)
        }
        .sheet(isPresented: $session.isSettingsPresented) {
            SettingsView()
                .zoomTransition(from: session.accountSheetSource, in: zoom)
        }
        .sheet(isPresented: $session.isQuickVoiceMemoPresented) { QuickVoiceMemoSheet() }
    }
}
