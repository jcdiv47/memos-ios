import Foundation

/// Uploads one file through `AttachmentService.UploadAttachment`, in the chunk size the server
/// asks for. The attachment ID is picked by the caller, so a retry after a lost response finds
/// the finished upload instead of making a second one.
public enum AttachmentUpload {
    public static func upload(
        _ data: Data,
        filename: String,
        mimeType: String,
        attachmentID: String,
        client: MemosClient
    ) async throws(APIError) -> Attachment {
        var spec = Memos_Api_UploadAttachmentSpec()
        spec.attachment.filename = filename
        spec.attachment.type = mimeType
        spec.attachmentID = attachmentID
        spec.totalSize = Int64(data.count)
        var start = Memos_Api_UploadAttachmentRequest()
        start.spec = spec
        start.writeOffset = 0

        do throws(APIError) {
            var response = try await client.call(client.attachments.uploadAttachment(request:headers:), start)
            let chunk = Int(max(response.maxChunkSize, 64 * 1024))
            var offset = Int(response.committedSize)
            let uploadID = response.uploadID
            repeat {
                var request = Memos_Api_UploadAttachmentRequest()
                request.uploadID = uploadID
                request.writeOffset = Int64(offset)
                let end = min(offset + chunk, data.count)
                request.data = data.subdata(in: offset..<end)
                request.finishWrite = end == data.count
                response = try await client.call(client.attachments.uploadAttachment(request:headers:), request)
                offset = Int(response.committedSize)
            } while !response.hasAttachment && offset < data.count
            guard response.hasAttachment else { throw APIError(code: .dataLoss, message: String(localized: "The upload didn’t finish.", bundle: .module)) }
            return response.attachment
        } catch {
            // A retry of an upload that already finished: the server reports the duplicate ID as
            // an internal error rather than ALREADY_EXISTS, so look before giving up.
            guard !error.isConnectivity else { throw error }
            var request = Memos_Api_GetAttachmentRequest()
            request.name = "attachments/\(attachmentID)"
            if let existing = try? await client.call(client.attachments.getAttachment(request:headers:), request) {
                return existing
            }
            throw error
        }
    }

    /// Creates a memo straight on the server, files first: what an extension does before it
    /// falls back to leaving the draft for the app. Safe to repeat with the same draft.
    public static func create(_ draft: ExtensionDraft, files: [String: Data], client: MemosClient) async throws(APIError) -> Memo {
        // An earlier attempt may have gone through with its response lost. Creating again would
        // fail on the attachments, which are already bound to that memo.
        var existing = Memos_Api_GetMemoRequest()
        existing.name = "memos/\(draft.uid)"
        if let memo = try? await client.call(client.memos.getMemo(request:headers:), existing) {
            return memo
        }
        var references: [Attachment] = []
        for (index, file) in draft.files.enumerated() {
            guard let data = files[file.storedName] else { continue }
            let id = draft.attachmentID(index)
            let uploaded = try await upload(data, filename: file.filename, mimeType: file.mimeType, attachmentID: id, client: client)
            var reference = Attachment()
            reference.name = uploaded.name
            references.append(reference)
        }
        var request = Memos_Api_CreateMemoRequest()
        request.memo.content = draft.content
        request.memo.visibility = MemoVisibility(filterValue: draft.visibility) ?? .private
        request.memo.state = .normal
        request.memo.attachments = references
        request.memoID = draft.uid
        do throws(APIError) {
            return try await client.call(client.memos.createMemo(request:headers:), request)
        } catch where error.code == .alreadyExists {
            var get = Memos_Api_GetMemoRequest()
            get.name = "memos/\(draft.uid)"
            return try await client.call(client.memos.getMemo(request:headers:), get)
        }
    }
}
