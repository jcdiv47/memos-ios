import CoreLocation
import MapKit
import MemosCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The draft in the composer: text, audience, attachments and place.
@Observable
final class ComposerModel {
    var text = AttributedString()
    var selection = AttributedTextSelection()
    var visibility: MemoVisibility = .private
    var space: String?
    /// A one-tap alternative audience, such as “Share with Studio”.
    var suggestion: MemoVisibility?
    var attachments: [Attachment] = []
    var location: MemoLocation?
    var isLocating = false
    var error: String?

    /// The memo being edited, or nil for a new one.
    private(set) var editing: Memo?

    var plainText: String { String(text.characters) }
    var isEmpty: Bool { plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }

    var hasChanges: Bool {
        guard let editing else { return !isEmpty }
        return plainText != editing.content || visibility != editing.visibility || space != editing.spaceName
            || attachments.map(\.name) != editing.attachments.map(\.name) || location != editing.locationIfSet
    }

    init(request: ComposerRequest, session: AccountSession) {
        switch request.mode {
        case .new(let origin, let text, _, _):
            let initial = VisibilityRules.initial(defaultVisibility: session.defaultVisibility, origin: origin)
            visibility = initial.visibility
            suggestion = initial.suggestion
            switch origin {
            case .timeline(let space), .view(let space, _): self.space = space
            case .shareSheet, .silent: space = nil
            }
            setText(text)
        case .edit(let name):
            guard let memo = session.store.own[name] else { return }
            editing = memo
            visibility = memo.visibility
            space = memo.spaceName
            attachments = memo.attachments
            location = memo.locationIfSet
            if space != nil && visibility == .private { suggestion = .space }
            setText(memo.content)
        }
    }

    private func setText(_ string: String) {
        text = AttributedString(string)
        selection = AttributedTextSelection(range: text.endIndex..<text.endIndex)
        highlightTags()
    }

    // MARK: Text

    /// Tags you type with # turn Memos Blue.
    func highlightTags() {
        let plain = plainText
        let matches = TagScanner.matches(in: plain, excluding: TagScanner.codeSpans(in: plain))
        var tagRanges: [Range<AttributedString.Index>] = []
        for match in matches {
            let lower = plain.distance(from: plain.startIndex, to: match.range.lowerBound)
            let length = plain.distance(from: match.range.lowerBound, to: match.range.upperBound)
            let start = text.characters.index(text.startIndex, offsetBy: lower)
            tagRanges.append(start..<text.characters.index(start, offsetBy: length))
        }
        let current = text.runs.compactMap { run in run.foregroundColor == .memosBlue ? run.range : nil }
        guard current != tagRanges else { return }
        text.transform(updating: &selection) { text in
            text.foregroundColor = nil
            for range in tagRanges {
                text[range].foregroundColor = .memosBlue
            }
        }
    }

    /// Inserts `string` at the cursor, replacing any selection.
    func insert(_ string: String) {
        text.replaceSelection(&selection, withCharacters: string)
        highlightTags()
    }

    /// Starts a new line with `prefix` (a checkbox or a bullet), unless the cursor is already at
    /// the start of a line.
    func insertLinePrefix(_ prefix: String) {
        let plain = plainText
        let needsNewline = !plain.isEmpty && !plain.hasSuffix("\n") && cursorAtEnd
        insert((needsNewline ? "\n" : "") + prefix)
    }

    /// Wraps the selection in `marker` (`**` for bold, `` ` `` for code), or inserts a pair.
    func wrap(_ marker: String) {
        let selected = String(text[selection].characters)
        insert(marker + selected + marker)
    }

    private var cursorAtEnd: Bool {
        if case .insertionPoint(let index) = selection.indices(in: text) { return index == text.endIndex }
        return false
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
            let name = "IMG_\(Int(Date.now.timeIntervalSince1970) % 100_000).\(type.preferredFilenameExtension ?? "jpg")"
            stage(data: data, filename: name, type: type, store: store)
        }
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

    private func stage(data: Data, filename: String, type: UTType, store: MemoStore) {
        do {
            let attachment = try store.stageUpload(data: data, filename: filename, mimeType: type.preferredMIMEType ?? "application/octet-stream")
            withAnimation(.memosSpring) { attachments.append(attachment) }
        } catch {
            self.error = "Couldn’t add \(filename)."
        }
    }

    func remove(_ attachment: Attachment, store: MemoStore) {
        withAnimation(.memosSpring) { attachments.removeAll { $0.name == attachment.name } }
        if store.isStaged(attachment), editing?.attachments.contains(where: { $0.name == attachment.name }) != true {
            try? FileManager.default.removeItem(at: store.location.uploadFile(for: attachment.name))
        }
    }

    /// Staged files that never made it into a saved memo.
    func discardStaged(store: MemoStore) {
        for attachment in attachments where store.isStaged(attachment) && editing?.attachments.contains(where: { $0.name == attachment.name }) != true {
            try? FileManager.default.removeItem(at: store.location.uploadFile(for: attachment.name))
        }
    }

    // MARK: Location

    func addCurrentLocation() async {
        isLocating = true
        defer { isLocating = false }
        guard let fix = await LocationFetcher.current() else {
            error = "Couldn’t find where you are. Check that Location Services are on for Memos."
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
        let content = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else { return false }
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
