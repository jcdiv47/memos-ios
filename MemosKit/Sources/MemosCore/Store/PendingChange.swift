import Foundation

/// A change to one of your own memos that hasn't reached the server yet. Changes upload in the
/// order they were made; the memo's current local state is what gets sent.
public struct PendingChange: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// The memo's resource name, `memos/{uid}`. The app picks the UID for new memos.
    public var memo: String
    public var operation: Operation
    public var createdAt: Date
    public var attempts: Int
    /// Set when the server rejected the change for a reason retrying won't fix. The change
    /// stays queued, and visible, until the person deals with it.
    public var failure: String?

    public enum Operation: Codable, Equatable, Sendable {
        case create
        case update(fields: Set<MemoField>, base: BaseVersion?)
        case delete
        /// Uploads a file for `memo` before the memo itself is created or updated.
        case uploadAttachment(attachment: String)
    }

    /// Whether uploading this change sends the memo's text.
    public var sentContent: Bool {
        switch operation {
        case .create: true
        case .update(let fields, _): fields.contains(.content)
        default: false
        }
    }

    public init(memo: String, operation: Operation, createdAt: Date = .now) {
        self.id = UUID()
        self.memo = memo
        self.operation = operation
        self.createdAt = createdAt
        self.attempts = 0
        self.failure = nil
    }
}

/// An update mask path the app sends.
public enum MemoField: String, Codable, Hashable, Sendable, CaseIterable {
    case content
    case visibility
    case pinned
    case state
    case space
    case location
    case attachments
    /// The memos this one links to. Sent as the complete set.
    case relations
}

/// The server version an edit started from, used to detect that someone else changed the text
/// in the meantime.
public struct BaseVersion: Codable, Equatable, Sendable {
    public var updateTime: Date
    public var content: String

    public init(updateTime: Date, content: String) {
        self.updateTime = updateTime
        self.content = content
    }
}

extension Array where Element == PendingChange {
    /// Adds `change`, merging it into what's already queued for the same memo where the
    /// result uploads the same thing in fewer requests. `inFlight` is the change being uploaded
    /// right now, which must not be merged into.
    public mutating func enqueue(_ change: PendingChange, inFlight: UUID? = nil) {
        let mergeable = { (existing: PendingChange) in existing.memo == change.memo && existing.id != inFlight && existing.failure == nil }

        // A merge target must come after every attachment upload queued for the memo: a change
        // that runs before an upload can't reference the uploaded file.
        let lastUpload = lastIndex { existing in
            if case .uploadAttachment = existing.operation { existing.memo == change.memo } else { false }
        }
        let afterUploads = { (index: Int) in lastUpload.map { index > $0 } ?? true }

        switch change.operation {
        case .update(let fields, let base):
            // A queued create sends the memo's latest state anyway.
            if let index = firstIndex(where: { mergeable($0) && $0.operation == .create }), afterUploads(index) { return }
            if let index = lastIndex(where: mergeable), afterUploads(index),
               case .update(let existingFields, let existingBase) = self[index].operation {
                self[index].operation = .update(fields: existingFields.union(fields), base: existingBase ?? base)
                return
            }
            append(change)

        case .delete:
            let hadQueuedCreate = contains { mergeable($0) && $0.operation == .create }
            // Nothing queued for the memo matters once it's deleted, failed changes included.
            removeAll { $0.memo == change.memo && $0.id != inFlight }
            // A memo that never reached the server needs no delete.
            if hadQueuedCreate && !contains(where: { $0.memo == change.memo }) { return }
            append(change)

        case .create, .uploadAttachment:
            append(change)
        }
    }
}
