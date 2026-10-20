import Foundation

/// A memo saved by the share extension or a widget while the app wasn't running.
///
/// Extensions never write the app's local copy or queue directly, since the app may be writing
/// them at the same moment. They try to upload the memo themselves, and if that fails they leave
/// it here; the app imports it into its queue the next time it comes to the foreground. The UID
/// is chosen once, so an upload that went through but lost its response is not duplicated.
public struct ExtensionDraft: Codable, Sendable, Identifiable {
    public struct File: Codable, Sendable {
        public var filename: String
        public var mimeType: String
        /// Name of the file next to the draft in the inbox.
        public var storedName: String

        public init(filename: String, mimeType: String, storedName: String) {
            self.filename = filename
            self.mimeType = mimeType
            self.storedName = storedName
        }
    }

    public var id: String { uid }
    public var uid: String
    public var content: String
    public var visibility: String
    public var files: [File]
    public var createdAt: Date

    /// The ID of the draft's `index`th file. Fixed, so every attempt uploads to the same one.
    public func attachmentID(_ index: Int) -> String {
        "\(uid.prefix(20))-\(index)"
    }

    public init(uid: String = ResourceID.generate(), content: String, visibility: MemoVisibility, files: [File] = [], createdAt: Date = .now) {
        self.uid = uid
        self.content = content
        self.visibility = visibility.filterValue
        self.files = files
        self.createdAt = createdAt
    }
}

public enum ExtensionInbox {
    /// Leaves a draft for the app, with its files.
    public static func drop(_ draft: ExtensionDraft, files: [String: Data], in location: AccountLocation) throws {
        let directory = location.inboxDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in files {
            try data.write(to: directory.appending(path: name), options: .atomic)
        }
        try JSONEncoder().encode(draft).write(to: directory.appending(path: "\(draft.uid).json"), options: .atomic)
    }

    /// Moves every waiting draft into the store's queue.
    @MainActor
    public static func drain(into store: MemoStore) {
        let directory = store.location.inboxDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let draft = try? JSONDecoder().decode(ExtensionDraft.self, from: data) else {
                continue
            }
            if store.own["memos/\(draft.uid)"] == nil {
                var attachments: [Attachment] = []
                for (index, file) in draft.files.enumerated() {
                    let fileURL = directory.appending(path: file.storedName)
                    // The same attachment IDs the extension used, so a file it already uploaded
                    // is found rather than uploaded again.
                    if let bytes = try? Data(contentsOf: fileURL),
                       let staged = try? store.stageUpload(data: bytes, filename: file.filename, mimeType: file.mimeType, attachmentID: draft.attachmentID(index)) {
                        attachments.append(staged)
                    }
                }
                var memoDraft = MemoDraft(content: draft.content, visibility: MemoVisibility(filterValue: draft.visibility) ?? .private, attachments: attachments)
                memoDraft.uid = draft.uid
                memoDraft.createdAt = draft.createdAt
                store.create(memoDraft)
            }
            for file in draft.files {
                try? FileManager.default.removeItem(at: directory.appending(path: file.storedName))
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
