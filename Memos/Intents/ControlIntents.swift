import AppIntents
#if !WIDGET_EXTENSION
import MemosCore
#endif

// Shared by the app and the widget extension: the controls and widgets declare these, and the
// system runs them in the app, which they open.

/// Opens the composer, as from a widget: your default visibility and no Space.
struct NewMemoIntent: AppIntent {
    static let title: LocalizedStringResource = "New Memo"
    static let description = IntentDescription("Opens Memos to write a new memo.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let session = try await IntentEnvironment.session()
        session.capture(origin: .shareSheet)
        #endif
        return .result()
    }
}

/// Records a voice memo and saves it without showing the composer, so it stays Private.
struct VoiceMemoIntent: AppIntent {
    static let title: LocalizedStringResource = "Voice Memo"
    static let description = IntentDescription("Records a private voice memo, transcribed.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let session = try await IntentEnvironment.session()
        session.isQuickVoiceMemoPresented = true
        #endif
        return .result()
    }
}
