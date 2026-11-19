import CoreLocation
import MapKit
import MemosCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The draft in the composer: text, audience, attachments and place. Every change is kept as a
/// draft until the memo is saved or discarded, so closing the sheet or the app loses nothing.
@Observable
final class ComposerModel {
    var text = "" {
        didSet { if text != oldValue { draftChanged() } }
    }
    /// The selection in UTF-16 offsets, as the text view counts them.
    var selection = NSRange(location: 0, length: 0)
    /// Whether an input method has marked text, which formatting has to leave alone.
    private(set) var isComposing = false
    /// Your tags that match the `#tag` at the cursor.
    private(set) var tagSuggestions: [String] = []
    /// A date like “tomorrow 8pm” just before the cursor, which one tap writes out in full.
    private(set) var datePhrase: DatePhrase?
    var visibility: MemoVisibility = .private {
        didSet { if visibility != oldValue { draftChanged() } }
    }
    var space: String? {
        didSet { if space != oldValue { draftChanged() } }
    }
    /// A one-tap alternative audience, such as “Share with Studio”.
    var suggestion: MemoVisibility? {
        didSet { if suggestion != oldValue { draftChanged() } }
    }
    var attachments: [Attachment] = [] {
        didSet { if attachments.map(\.name) != oldValue.map(\.name) { draftChanged() } }
    }
    var location: MemoLocation? {
        didSet { if location != oldValue { draftChanged() } }
    }
    var isLocating = false
    /// Photos and scans still being turned into files.
    private(set) var preparing = 0
    var error: String?
    /// Something worth knowing that isn't a failure, like a draft that no longer applied.
    var notice: String?

    /// The memo being edited, or nil for a new one.
    private(set) var editing: Memo?

    @ObservationIgnored let editor = EditorProxy()
    @ObservationIgnored private let drafts: DraftStore
    @ObservationIgnored private let draftKey: DraftKey
    @ObservationIgnored private let store: MemoStore
    /// Your tags, most used first, for completion. Counted the first time a tag is typed rather
    /// than while the sheet is opening.
    @ObservationIgnored private lazy var tags: [String] = store.tagCounts().map(\.tag)
    /// Off while the fields are filled in, and once the memo is saved or discarded: neither
    /// should write the draft.
    @ObservationIgnored private var keepsDraft = false

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }

    var hasChanges: Bool {
        guard let editing else { return !isEmpty }
        return text != editing.content || visibility != editing.visibility || space != editing.spaceName
            || attachments.map(\.name) != editing.attachments.map(\.name) || location != editing.locationIfSet
    }

    init(request: ComposerRequest, session: AccountSession) {
        drafts = session.drafts
        store = session.store
        switch request.mode {
        case .new(let origin, let text, _, _):
            draftKey = .newMemo
            let initial = VisibilityRules.initial(defaultVisibility: session.defaultVisibility, origin: origin)
            visibility = initial.visibility
            suggestion = initial.suggestion
            switch origin {
            case .timeline(let space), .view(let space, _): self.space = space
            case .shareSheet, .silent: space = nil
            }
            if let draft = drafts.draft(for: .newMemo) {
                restore(draft, session: session)
                // Shared or linked text joins the draft rather than replacing it.
                self.text = Self.joining(text, to: self.text)
            } else {
                self.text = text
            }
        case .edit(let name):
            draftKey = .edit(name)
            guard let memo = session.store.own[name] else { break }
            editing = memo
            visibility = memo.visibility
            space = memo.spaceName
            attachments = memo.attachments
            location = memo.locationIfSet
            if space != nil && visibility == .private { suggestion = .space }
            text = memo.content
            if let draft = drafts.draft(for: draftKey) {
                if draft.isCurrent(for: memo) {
                    restore(draft, session: session)
                } else {
                    // Saving it would quietly undo whatever changed since.
                    removeStaged(draft.attachments, store: session.store)
                    drafts.remove(draftKey)
                    notice = String(localized: "This memo changed since you last edited it, so your unsaved changes were discarded.")
                }
            }
        }
        selection = NSRange(location: (text as NSString).length, length: 0)
        keepsDraft = true
    }

    private func restore(_ draft: ComposerDraft, session: AccountSession) {
        text = draft.text
        visibility = draft.visibility
        space = draft.space
        suggestion = draft.suggestion
        location = draft.location
        // A staged file can be missing if the app stopped between staging it and saving the draft.
        attachments = draft.attachments.filter { attachment in
            session.store.isStaged(attachment) || editing?.attachments.contains { $0.name == attachment.name } == true
        }
        if let space, session.store.profile.user != nil, session.space(named: space) == nil {
            setSpace(nil)
        }
    }

    /// `addition` after `base`, with a blank line between them.
    static func joining(_ addition: String, to base: String) -> String {
        guard !addition.isEmpty else { return base }
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == addition ? addition : trimmed + "\n\n" + addition
    }

    // MARK: Text

    /// Called by the text view after every keystroke and selection change.
    func editorDidChange(text: String, selection: NSRange, isComposing: Bool) {
        if self.text != text { self.text = text }
        if self.selection != selection { self.selection = selection }
        if self.isComposing != isComposing { self.isComposing = isComposing }
        if !isComposing { updateSuggestions() }
    }

    /// Replaces the whole text, as a transcript does, leaving the cursor at the end.
    func replaceText(_ string: String) {
        text = string
        selection = NSRange(location: (string as NSString).length, length: 0)
    }

    func format(_ format: MarkdownFormat) {
        let (text, selection) = current
        apply(MarkdownEditing.edit(format, in: text, selection: selection))
    }

    func insertTag() {
        let (text, selection) = current
        apply(MarkdownEditing.insertTagMarker(in: text, selection: selection))
    }

    /// Finishes the `#tag` at the cursor with `tag` and a space.
    func completeTag(_ tag: String) {
        let (text, selection) = current
        guard let token = MarkdownEditing.tagToken(in: text, at: selection.location) else { return }
        apply(MarkdownEditing.completeTag(tag, replacing: token, in: text))
    }

    /// Writes the date before the cursor out in full, in this device's time zone, so the memo
    /// still says when once “tomorrow” has passed.
    func convertDate() {
        let (text, selection) = current
        // Read again rather than reusing the suggestion: “tomorrow” may have moved since.
        guard selection.length == 0, let phrase = DatePhrases.phrase(in: text, before: selection.location) else { return }
        apply(DatePhrases.convert(phrase, in: text, cursor: selection.location))
    }

    private var current: (text: String, selection: NSRange) {
        editor.snapshot ?? (text, selection)
    }

    /// Through the text view, so the edit can be undone; straight to the text before there is one.
    private func apply(_ edit: TextEdit) {
        if editor.isAttached {
            editor.apply(edit)
        } else {
            text = edit.applied(to: text)
            selection = edit.selection
            updateSuggestions()
        }
    }

    private func updateSuggestions() {
        var suggestions: [String] = []
        var phrase: DatePhrase?
        if selection.length == 0 {
            if let token = MarkdownEditing.tagToken(in: text, at: selection.location) {
                suggestions = MarkdownEditing.tagSuggestions(for: token.prefix, in: tags)
            } else {
                phrase = DatePhrases.phrase(in: text, before: selection.location)
            }
        }
        if suggestions != tagSuggestions { tagSuggestions = suggestions }
        if phrase != datePhrase { datePhrase = phrase }
    }

    // MARK: Audience

    /// Moves the draft into a Space or out of one. Protected and Public narrow to Space inside
    /// a Space; Space visibility falls back to Private without one.
    func setSpace(_ newSpace: String?) {
        guard newSpace != space else { return }
        space = newSpace
        if newSpace == nil {
            visibility = VisibilityRules.afterRemovingSpace(visibility)
            if suggestion == .space { suggestion = nil }
        } else {
            visibility = VisibilityRules.afterAddingSpace(visibility)
            // Moving a Private memo into a Space doesn't share it; one tap does.
            if visibility == .private { suggestion = .space }
        }
    }

    func applySuggestion() {
        guard let suggestion else { return }
        visibility = suggestion
        self.suggestion = nil
    }

    // MARK: Attachments

    func addPhotos(_ items: [PhotosPickerItem], store: MemoStore) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first { $0.conforms(to: .image) || $0.conforms(to: .movie) } ?? .jpeg
            let name = "IMG_\(Self.stamp).\(type.preferredFilenameExtension ?? "jpg")"
            stage(data: data, filename: name, type: type, store: store)
        }
    }

    func addCameraPhoto(_ image: UIImage, store: MemoStore) async {
        preparing += 1
        defer { preparing -= 1 }
        guard let data = await CapturedMedia.jpeg(image) else {
            error = String(localized: "Couldn’t add the photo.")
            return
        }
        stage(data: data, filename: "IMG_\(Self.stamp).jpg", type: .jpeg, store: store)
    }

    /// The scanned pages, as one PDF.
    func addScan(_ pages: [UIImage], store: MemoStore) async {
        guard !pages.isEmpty else { return }
        preparing += 1
        defer { preparing -= 1 }
        let data = await CapturedMedia.pdf(pages)
        stage(data: data, filename: "Scan_\(Self.stamp).pdf", type: .pdf, store: store)
    }

    func addFiles(_ urls: [URL], store: MemoStore) {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            stage(data: data, filename: url.lastPathComponent, type: type, store: store)
        }
    }

    func addAudio(_ url: URL, store: MemoStore) {
        guard let data = try? Data(contentsOf: url) else { return }
        stage(data: data, filename: url.lastPathComponent, type: .mpeg4Audio, store: store)
        try? FileManager.default.removeItem(at: url)
    }

    private static var stamp: Int { Int(Date.now.timeIntervalSince1970) % 100_000 }

    private func stage(data: Data, filename: String, type: UTType, store: MemoStore) {
        do {
            let attachment = try store.stageUpload(data: data, filename: filename, mimeType: type.preferredMIMEType ?? "application/octet-stream")
            withAnimation(.memosSpring) { attachments.append(attachment) }
        } catch {
            self.error = String(localized: "Couldn’t add \(filename).")
        }
    }

    func remove(_ attachment: Attachment, store: MemoStore) {
        withAnimation(.memosSpring) { attachments.removeAll { $0.name == attachment.name } }
        removeStaged([attachment], store: store)
    }

    /// Deletes staged files that never made it into a saved memo.
    private func removeStaged(_ attachments: [Attachment], store: MemoStore) {
        for attachment in attachments where store.isStaged(attachment) && editing?.attachments.contains(where: { $0.name == attachment.name }) != true {
            try? FileManager.default.removeItem(at: store.location.uploadFile(for: attachment.name))
        }
    }

    // MARK: Draft

    private var draft: ComposerDraft {
        ComposerDraft(
            text: text, visibility: visibility, space: space, suggestion: suggestion,
            attachments: attachments, location: location,
            base: editing.map { BaseVersion(updateTime: $0.updatedAt, content: $0.content) }
        )
    }

    private func draftChanged() {
        guard keepsDraft else { return }
        if hasChanges {
            drafts.save(draft, for: draftKey)
        } else {
            drafts.remove(draftKey)
        }
    }

    /// Closing without saving: the draft and its staged files stay for next time.
    func keepDraft() {
        guard keepsDraft else { return }
        drafts.flush()
    }

    /// Throws the draft away, with any files staged for it.
    func discard(store: MemoStore) {
        keepsDraft = false
        removeStaged(attachments, store: store)
        drafts.remove(draftKey)
    }

    // MARK: Location

    func addCurrentLocation() async {
        isLocating = true
        defer { isLocating = false }
        guard let fix = await LocationFetcher.current() else {
            error = String(localized: "Couldn’t find where you are. Check that Location Services are on for Memos.")
            return
        }
        var location = MemoLocation()
        location.latitude = fix.coordinate.latitude
        location.longitude = fix.coordinate.longitude
        location.placeholder = await LocationFetcher.name(for: fix) ?? fix.coordinate.formatted
        withAnimation(.memosSpring) { self.location = location }
    }

    // MARK: Saving

    /// Saves to the local copy; the upload follows in the background. Returns false when there's
    /// nothing to save.
    func save(to store: MemoStore) -> Bool {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else { return false }
        keepsDraft = false
        drafts.remove(draftKey)
        if let editing {
            var fields: Set<MemoField> = []
            if content != editing.content { fields.insert(.content) }
            if visibility != editing.visibility || space != editing.spaceName { fields.formUnion([.visibility, .space]) }
            if attachments.map(\.name) != editing.attachments.map(\.name) { fields.insert(.attachments) }
            if location != editing.locationIfSet { fields.insert(.location) }
            guard !fields.isEmpty else { return true }
            // The base is the version the composer opened with: if a sync brought in someone
            // else's text meanwhile, uploading this is a conflict, not an overwrite.
            store.update(editing.name, fields: fields, base: BaseVersion(updateTime: editing.updatedAt, content: editing.content)) { memo in
                memo.content = content
                memo.visibility = space == nil ? VisibilityRules.afterRemovingSpace(visibility) : visibility
                memo.spaceName = space
                memo.attachments = attachments
                if let location { memo.location = location } else { memo.clearLocation() }
            }
        } else {
            store.create(MemoDraft(content: content, visibility: visibility, space: space, location: location, attachments: attachments))
        }
        return true
    }
}

extension CLLocationCoordinate2D {
    var formatted: String {
        "\(latitude.formatted(.number.precision(.fractionLength(4)))), \(longitude.formatted(.number.precision(.fractionLength(4))))"
    }
}

/// One location fix, asked for when someone adds a place to a memo.
enum LocationFetcher {
    static func current() async -> CLLocation? {
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if update.authorizationDenied || update.authorizationRestricted { return nil }
                if let location = update.location, location.horizontalAccuracy < 200 { return location }
            }
        } catch {
            return nil
        }
        return nil
    }

    static func name(for location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first
        else { return nil }
        return item.name ?? item.address?.shortAddress
    }
}
