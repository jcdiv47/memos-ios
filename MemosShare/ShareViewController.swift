import MemosCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Saves a link, some text or photos as a memo. It opens with your default visibility and no
/// Space, and the audience chip is visible before you save.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareComposer(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}

@Observable
final class ShareModel {
    var text = ""
    var images: [(name: String, data: Data, type: UTType)] = []
    var visibility: MemoVisibility = .private
    var isSaving = false
    var error: String?
    private(set) var signedIn = AccountLocation.current != nil

    @ObservationIgnored private weak var context: NSExtensionContext?

    init(context: NSExtensionContext?) {
        self.context = context
    }

    func load() async {
        if let location = AccountLocation.current {
            let profile = await AccountArchive.readProfile(location)
            visibility = VisibilityRules.initial(
                defaultVisibility: profile.defaultVisibility.flatMap(MemoVisibility.init(filterValue:)),
                origin: .shareSheet
            ).visibility
        }
        var parts: [String] = []
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                parts.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      let data = try? await Self.loadData(provider, type: .image) {
                let type = provider.registeredContentTypes.first { $0.conforms(to: .image) } ?? .jpeg
                images.append(("Photo \(images.count + 1).\(type.preferredFilenameExtension ?? "jpg")", data, type))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let string = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                parts.append(string)
            }
        }
        text = parts.joined(separator: "\n\n")
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
            }
        }
    }

    /// Uploads straight away when it can; otherwise leaves the memo for the app to upload.
    func save() async {
        guard let location = AccountLocation.current, let server = AccountLocation.currentServer else {
            error = String(localized: "Open Memos and sign in first.")
            return
        }
        isSaving = true
        defer { isSaving = false }
        let files = images.enumerated().map { index, image in
            ExtensionDraft.File(filename: image.name, mimeType: image.type.preferredMIMEType ?? "image/jpeg", storedName: "file-\(index)")
        }
        let draft = ExtensionDraft(content: text.trimmingCharacters(in: .whitespacesAndNewlines), visibility: visibility, files: files)
        let data = Dictionary(uniqueKeysWithValues: images.enumerated().map { ("file-\($0.offset)", $0.element.data) })

        let client = MemosClient(serverURL: server, credentialStore: KeychainCredentialStore())
        do {
            _ = try await AttachmentUpload.create(draft, files: data, client: client)
        } catch {
            do {
                try ExtensionInbox.drop(draft, files: data, in: location)
            } catch {
                self.error = String(localized: "Couldn’t save the memo.")
                return
            }
        }
        context?.completeRequest(returningItems: nil)
    }

    func cancel() {
        context?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}

struct ShareComposer: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if !model.signedIn {
                    Text("Open Memos and sign in to save memos from here.")
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: $model.text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
                if !model.images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Array(model.images.enumerated()), id: \.offset) { _, image in
                                if let uiImage = UIImage(data: image.data) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipShape(.rect(cornerRadius: 10))
                                }
                            }
                        }
                    }
                }
                Menu {
                    Picker("Visibility", selection: $model.visibility) {
                        ForEach([MemoVisibility.private, .protected, .public], id: \.self) { visibility in
                            Label(visibility.label, systemImage: visibility.systemImage).tag(visibility)
                        }
                    }
                } label: {
                    Label(model.visibility.label, systemImage: model.visibility.systemImage)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: .capsule)
                }
                if let error = model.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle("Save to Memos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await model.save() } }
                        .buttonStyle(.glassProminent)
                        .disabled(!model.signedIn || model.isSaving || (model.text.isEmpty && model.images.isEmpty))
                }
            }
        }
    }
}
