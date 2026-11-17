import AppIntents
import CoreSpotlight
import MemosCore
import SwiftProtobuf
import SwiftUI
import WidgetKit

/// The signed-in session, for intents. Intents run in the app's process; when the system
/// launches the app just to run one, the session is restored here first.
enum IntentEnvironment {
    static func session() async throws -> AccountSession {
        let model = AppModel.shared
        await model.restore()
        guard let session = model.session else {
            throw IntentError.signedOut
        }
        await session.store.load()
        return session
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case notYours
    case notYoursToPin
    case empty

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Open Memos and sign in first."
        case .notYours: "You can only add to your own memos."
        case .notYoursToPin: "You can only pin your own memos."
        case .empty: "There’s nothing to save."
        }
    }
}

/// A memo, for Shortcuts and Spotlight.
struct MemoEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Memo"
    static let defaultQuery = MemoEntityQuery()

    /// The memo's resource name, `memos/{uid}`.
    var id: String

    @Property(title: "Content")
    var content: String

    @Property(title: "Created")
    var createdAt: Date

    @Property(title: "Tags")
    var tags: [String]

    var title: String
    /// Blurred by one of your tag rules. As in the widgets, Spotlight and the Shortcuts picker
    /// then show “Sensitive content” and none of its text or tags. The content stays readable
    /// to a shortcut that asks for it.
    var sensitive = false

    init(_ memo: Memo, rules: TagBlurRules = TagBlurRules()) {
        id = memo.name
        title = memo.displayTitle
        content = memo.content
        createdAt = memo.createdAt
        tags = memo.tags
        sensitive = rules.blurs(memo)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: sensitive ? "Sensitive content" : "\(title)",
            subtitle: "\(createdAt.formatted(date: .abbreviated, time: .shortened))"
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet()
        attributes.contentCreationDate = createdAt
        if sensitive {
            attributes.title = String(localized: "Sensitive content")
            return attributes
        }
        attributes.title = title
        attributes.contentDescription = content
        attributes.keywords = tags
        return attributes
    }
}

struct MemoEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [MemoEntity.ID]) async throws -> [MemoEntity] {
        let session = try await IntentEnvironment.session()
        return identifiers.compactMap { session.store.memo(named: $0) }.map { MemoEntity($0, rules: session.store.profile.tagBlurRules) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MemoEntity] {
        let session = try await IntentEnvironment.session()
        guard let filter = SearchQuery(text: string).filter(), let parsed = try? MemoFilter(filter) else { return [] }
        return session.store.memos(MemoQuery(scope: .mine, filter: parsed, order: .newest)).prefix(30).map { MemoEntity($0, rules: session.store.profile.tagBlurRules) }
    }

    @MainActor
    func suggestedEntities() async throws -> [MemoEntity] {
        let session = try await IntentEnvironment.session()
        return session.store.memos(MemoQuery(scope: .mine)).prefix(10).map { MemoEntity($0, rules: session.store.profile.tagBlurRules) }
    }
}

enum VisibilityOption: String, AppEnum {
    case `private`, protected, `public`

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Visibility"
    static let caseDisplayRepresentations: [VisibilityOption: DisplayRepresentation] = [
        .private: DisplayRepresentation(title: "Private", image: .init(systemName: "lock")),
        .protected: DisplayRepresentation(title: "Protected", image: .init(systemName: "person.2")),
        .public: DisplayRepresentation(title: "Public", image: .init(systemName: "globe")),
    ]

    var visibility: MemoVisibility {
        switch self {
        case .private: .private
        case .protected: .protected
        case .public: .public
        }
    }
}

/// Creates a memo without opening the app. It's Private unless the Shortcut passes a
/// visibility: if you never saw the audience, nobody else sees the memo.
struct CreateMemoIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Memo"
    static let description = IntentDescription("Saves a new memo. It’s private unless you choose a visibility.")

    @Parameter(title: "Content", inputOptions: .init(multiline: true))
    var content: String

    @Parameter(title: "Visibility")
    var visibility: VisibilityOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Create memo \(\.$content)") {
            \.$visibility
        }
    }

    @MainActor
    func perform() async throws -> some ReturnsValue<MemoEntity> & ProvidesDialog {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IntentError.empty }
        let session = try await IntentEnvironment.session()
        let initial = VisibilityRules.initial(defaultVisibility: session.defaultVisibility, origin: .silent(explicit: visibility?.visibility))
        let memo = session.store.create(MemoDraft(content: text, visibility: initial.visibility))
        await session.engine.push()
        await session.store.save()
        // Shortcuts run this with the app in the background, which never reaches the reload
        // on leaving the foreground.
        WidgetCenter.shared.reloadAllTimelines()
        return .result(value: MemoEntity(memo), dialog: "Saved to Memos.")
    }
}

/// Adds text to the end of one of your memos.
struct AppendToMemoIntent: AppIntent {
    static let title: LocalizedStringResource = "Append to Memo"

    @Parameter(title: "Memo")
    var memo: MemoEntity

    @Parameter(title: "Text", inputOptions: .init(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Append \(\.$text) to \(\.$memo)")
    }

    @MainActor
    func perform() async throws -> some ReturnsValue<MemoEntity> {
        let session = try await IntentEnvironment.session()
        guard let existing = session.store.own[memo.id] else { throw IntentError.notYours }
        let separator = existing.content.hasSuffix("\n") || existing.content.isEmpty ? "" : "\n"
        session.store.setContent(existing.name, to: existing.content + separator + text)
        await session.engine.push()
        await session.store.save()
        WidgetCenter.shared.reloadAllTimelines()
        return .result(value: MemoEntity(session.store.own[existing.name] ?? existing))
    }
}

enum PinAction: String, AppEnum {
    case pin, unpin

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pin or Unpin"
    static let caseDisplayRepresentations: [PinAction: DisplayRepresentation] = [
        .pin: DisplayRepresentation(title: "Pin", image: .init(systemName: "pin")),
        .unpin: DisplayRepresentation(title: "Unpin", image: .init(systemName: "pin.slash")),
    ]
}

/// Pins or unpins one of your memos. An explicit action rather than a toggle, so running the
/// Shortcut twice doesn't undo it. Goes through the store like the swipe, so it works offline.
struct PinMemoIntent: AppIntent {
    static let title: LocalizedStringResource = "Pin Memo"
    static let description = IntentDescription("Pins a memo to the top of your timeline, or unpins it.")

    @Parameter(title: "Action", default: .pin)
    var action: PinAction

    @Parameter(title: "Memo")
    var memo: MemoEntity

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) \(\.$memo)")
    }

    @MainActor
    func perform() async throws -> some ReturnsValue<MemoEntity> & ProvidesDialog {
        let session = try await IntentEnvironment.session()
        guard let existing = session.store.own[memo.id] else { throw IntentError.notYoursToPin }
        let pinned = action == .pin
        if existing.pinned != pinned {
            session.store.setPinned(existing.name, pinned)
            await session.engine.push()
            await session.store.save()
            WidgetCenter.shared.reloadAllTimelines()
        }
        let result = MemoEntity(session.store.own[existing.name] ?? existing)
        return .result(value: result, dialog: pinned ? "Pinned." : "Unpinned.")
    }
}

/// Searches your memos, from the local copy, so it works offline.
struct SearchMemosIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Memos"

    @Parameter(title: "Search for")
    var query: String

    @MainActor
    func perform() async throws -> some ReturnsValue<[MemoEntity]> {
        let session = try await IntentEnvironment.session()
        guard let filter = SearchQuery(text: query).filter(), let parsed = try? MemoFilter(filter) else { return .result(value: []) }
        return .result(value: session.store.memos(MemoQuery(scope: .mine, filter: parsed, order: .newest)).prefix(50).map { MemoEntity($0, rules: session.store.profile.tagBlurRules) })
    }
}

struct OpenMemoIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Memo"

    @Parameter(title: "Memo")
    var target: MemoEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let session = try await IntentEnvironment.session()
        session.show(memo: target.id)
        return .result()
    }
}

struct MemosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewMemoIntent(), phrases: ["New \(.applicationName)", "Write a memo in \(.applicationName)"], shortTitle: "New Memo", systemImageName: "square.and.pencil")
        AppShortcut(intent: VoiceMemoIntent(), phrases: ["Record a \(.applicationName) voice memo"], shortTitle: "Voice Memo", systemImageName: "mic")
        AppShortcut(intent: CreateMemoIntent(), phrases: ["Save to \(.applicationName)"], shortTitle: "Create Memo", systemImageName: "plus.square")
        AppShortcut(intent: SearchMemosIntent(), phrases: ["Search \(.applicationName)"], shortTitle: "Search Memos", systemImageName: "magnifyingglass")
        AppShortcut(
            intent: PinMemoIntent(),
            phrases: ["\(\.$action) a memo in \(.applicationName)", "\(\.$action) a \(.applicationName) memo"],
            shortTitle: "Pin Memo",
            systemImageName: "pin"
        )
    }
}
