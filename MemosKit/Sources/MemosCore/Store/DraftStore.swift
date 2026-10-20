import Foundation
import Observation

/// What the composer had open, enough to put it back as it was. Staged attachments stay in the
/// upload area while a draft holds them.
public struct ComposerDraft: Codable, Equatable, Sendable {
    public var text: String
    private var visibilityValue: String
    public var space: String?
    private var suggestionValue: String?
    @ProtoValues public var attachments: [Attachment]
    @ProtoValue public var location: MemoLocation?
    /// For an edit, the version of the memo it started from.
    public var base: BaseVersion?
    public var savedAt: Date

    public var visibility: MemoVisibility {
        get { MemoVisibility(filterValue: visibilityValue) ?? .private }
        set { visibilityValue = newValue.filterValue }
    }

    /// The one-tap audience the composer offered, such as “Share with Studio”.
    public var suggestion: MemoVisibility? {
        get { suggestionValue.flatMap(MemoVisibility.init(filterValue:)) }
        set { suggestionValue = newValue?.filterValue }
    }

    public init(
        text: String,
        visibility: MemoVisibility,
        space: String? = nil,
        suggestion: MemoVisibility? = nil,
        attachments: [Attachment] = [],
        location: MemoLocation? = nil,
        base: BaseVersion? = nil,
        savedAt: Date = .now
    ) {
        self.text = text
        visibilityValue = visibility.filterValue
        self.space = space
        suggestionValue = suggestion?.filterValue
        _attachments = ProtoValues(attachments)
        _location = ProtoValue(location)
        self.base = base
        self.savedAt = savedAt
    }

    /// Whether an edit draft was started from `memo` as it is now. One started from an older
    /// version would quietly undo whatever changed since.
    public func isCurrent(for memo: Memo) -> Bool {
        guard let base else { return false }
        return base.content == memo.content && abs(base.updateTime.timeIntervalSince(memo.updatedAt)) < 0.001
    }
}

/// Which draft: the one new memo in progress, or an edit of a given memo.
public enum DraftKey: Hashable, Sendable {
    case newMemo
    /// The memo's resource name.
    case edit(String)

    var filename: String {
        switch self {
        case .newMemo: "new.json"
        case .edit(let name): "edit-\(ResourceName.lastSegment(name).filter { $0.isLetter || $0.isNumber || "-_".contains($0) }).json"
        }
    }
}

/// The composer's drafts for one account, as small files in the account's folder, so closing
/// the sheet, the app being killed or a crash doesn't lose what you were writing. Saves are
/// coalesced into one write shortly after the first; the folder goes when the account is erased.
@MainActor
@Observable
public final class DraftStore {
    public let directory: URL
    /// Whether a new memo is waiting, for the capture field's “Continue draft”.
    public private(set) var hasNewMemoDraft: Bool

    private enum Change {
        case save(ComposerDraft)
        case remove
    }

    @ObservationIgnored private var pending: [DraftKey: Change] = [:]
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private let delay: Duration

    public init(directory: URL, delay: Duration = .milliseconds(500)) {
        self.directory = directory
        self.delay = delay
        hasNewMemoDraft = FileManager.default.fileExists(atPath: directory.appending(path: DraftKey.newMemo.filename).path())
    }

    public func draft(for key: DraftKey) -> ComposerDraft? {
        switch pending[key] {
        case .save(let draft): return draft
        case .remove: return nil
        case nil: break
        }
        guard let data = try? Data(contentsOf: file(for: key)) else { return nil }
        return try? JSONDecoder().decode(ComposerDraft.self, from: data)
    }

    /// Keeps `draft`. It's written shortly, together with anything else saved meanwhile.
    public func save(_ draft: ComposerDraft, for key: DraftKey) {
        guard !isClosed else { return }
        pending[key] = .save(draft)
        if key == .newMemo, !hasNewMemoDraft { hasNewMemoDraft = true }
        guard writeTask == nil else { return }
        writeTask = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.writeTask = nil
            self.flush()
        }
    }

    /// Deletes a draft right away, so a discarded or saved memo can't come back after a crash.
    public func remove(_ key: DraftKey) {
        pending[key] = nil
        try? FileManager.default.removeItem(at: file(for: key))
        if key == .newMemo, hasNewMemoDraft { hasNewMemoDraft = false }
    }

    /// Writes whatever is waiting. Call when the composer closes and when the app moves to the
    /// background.
    public func flush() {
        writeTask?.cancel()
        writeTask = nil
        guard !isClosed, !pending.isEmpty else { return }
        let changes = pending
        pending = [:]
        let encoder = JSONEncoder()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (key, change) in changes {
            switch change {
            case .save(let draft):
                guard let data = try? encoder.encode(draft) else { continue }
                do {
                    try data.write(to: file(for: key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } catch {
                    // Tried again with the next save or flush.
                    if pending[key] == nil { pending[key] = change }
                }
            case .remove:
                try? FileManager.default.removeItem(at: file(for: key))
            }
        }
    }

    /// Deletes every draft and stops writing, for signing out.
    public func removeAll() {
        isClosed = true
        writeTask?.cancel()
        writeTask = nil
        pending = [:]
        try? FileManager.default.removeItem(at: directory)
        if hasNewMemoDraft { hasNewMemoDraft = false }
    }

    private func file(for key: DraftKey) -> URL {
        directory.appending(path: key.filename)
    }
}
