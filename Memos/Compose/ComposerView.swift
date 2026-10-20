import MemosCore
import PhotosUI
import SwiftUI

/// The composer: a sheet that sits on the keyboard, glass at partial height and opaque full
/// screen. The writing area and the audience chips are opaque, so there's no glass on glass;
/// formatting actions float above the keys and Save is the app's only tinted glass.
struct ComposerView: View {
    let request: ComposerRequest

    @Environment(AccountSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var model: ComposerModel?
    @State private var detent: PresentationDetent = .medium
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isPickingPhotos = false
    @State private var isImportingFiles = false
    @State private var confirmDiscard = false
    @State private var saved = 0
    @FocusState private var editorFocused: Bool

    static func transitionID(for request: ComposerRequest) -> String {
        if case .edit(let name) = request.mode { return "edit-\(name)" }
        return "capture"
    }

    var body: some View {
        NavigationStack {
            if let model {
                content(model)
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model?.hasChanges ?? false)
        .sensoryFeedback(.success, trigger: saved)
        .onAppear {
            if model == nil { model = ComposerModel(request: request, session: session) }
        }
    }

    private var title: String {
        if case .edit = request.mode { return "Edit memo" }
        return "New memo"
    }

    @ViewBuilder
    private func content(_ model: ComposerModel) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            if session.voice.phase != .idle && session.voice.phase != .finished {
                VoiceStatus(recorder: session.voice) {
                    Task { await finishRecording(model) }
                }
            }

            TextEditor(text: $model.text, selection: $model.selection)
                .font(.memoBody)
                .foregroundStyle(.ink)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .overlay(alignment: .topLeading) {
                    if model.plainText.isEmpty {
                        Text("Capture a thought…")
                            .font(.memoBody)
                            .foregroundStyle(.ink2)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.card, in: .rect(cornerRadius: 14))
                .onChange(of: model.text) { model.highlightTags() }

            if !model.attachments.isEmpty || model.location != nil {
                AttachmentStrip(model: model)
            }

            AudienceChips(model: model)

            if let error = model.error {
                Text(error)
                    .font(.metadata)
                    .foregroundStyle(.danger)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .cancel) {
                    if model.hasChanges { confirmDiscard = true } else { close(model) }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(model) }
                    .buttonStyle(.glassProminent)
                    .tint(.memosBlue)
                    .disabled(model.isEmpty || (model.editing != nil && !model.hasChanges) || session.voice.phase == .recording || session.voice.phase == .transcribing)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            ToolbarItemGroup(placement: .keyboard) {
                formattingActions(model)
            }
        }
        .confirmationDialog("Discard this memo?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { close(model) }
        }
        .photosPicker(isPresented: $isPickingPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .livePhotos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                await model.addPhotos(items, store: session.store)
                photoItems = []
            }
        }
        .fileImporter(isPresented: $isImportingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addFiles(urls, store: session.store) }
        }
        .task { await begin(model) }
    }

    @ViewBuilder
    private func formattingActions(_ model: ComposerModel) -> some View {
        Button { model.insert("#") } label: { Image(systemName: "number") }
            .accessibilityLabel("Tag")
        Button { model.insertLinePrefix("- [ ] ") } label: { Image(systemName: "checklist") }
            .accessibilityLabel("Task")
        Button { model.insertLinePrefix("- ") } label: { Image(systemName: "list.bullet") }
            .accessibilityLabel("Bulleted list")
        Button { model.wrap("**") } label: { Image(systemName: "bold") }
            .accessibilityLabel("Bold")
        Button { model.wrap("`") } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
            .accessibilityLabel("Code")
        Spacer()
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { isPickingPhotos = true }
            Button("Files", systemImage: "folder") { isImportingFiles = true }
            Button("Current Location", systemImage: "location") { Task { await model.addCurrentLocation() } }
        } label: {
            Image(systemName: "paperclip")
        }
        .accessibilityLabel("Attach")
        Button {
            Task { await toggleRecording(model) }
        } label: {
            Image(systemName: session.voice.isRecording ? "stop.fill" : "mic")
        }
        .accessibilityLabel(session.voice.isRecording ? "Stop recording" : "Record voice memo")
    }

    // MARK: Lifecycle

    private func begin(_ model: ComposerModel) async {
        guard case .new(_, _, let record, let voiceMemo) = request.mode else {
            editorFocused = true
            return
        }
        if voiceMemo {
            // The capture field stopped a recording; its transcript streams in here.
            await waitForTranscript(model)
        } else if record {
            await session.voice.start()
        } else {
            editorFocused = true
        }
    }

    private func toggleRecording(_ model: ComposerModel) async {
        if session.voice.isRecording {
            await finishRecording(model)
        } else {
            await session.voice.start()
        }
    }

    private func finishRecording(_ model: ComposerModel) async {
        guard let recording = await session.voice.stop(client: session.client, online: session.isOnline) else { return }
        apply(recording, to: model)
    }

    private func waitForTranscript(_ model: ComposerModel) async {
        while session.voice.phase == .transcribing || session.voice.phase == .recording {
            if model.plainText != session.voice.transcript {
                model.text = AttributedString(session.voice.transcript)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let recording = session.voice.lastRecording {
            apply(recording, to: model)
        }
    }

    private func apply(_ recording: VoiceRecorder.Recording, to model: ComposerModel) {
        let existing = model.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = recording.transcript
        let combined = existing.isEmpty || existing == transcript ? transcript : existing + "\n\n" + transcript
        model.text = AttributedString(combined)
        model.selection = AttributedTextSelection(range: model.text.endIndex..<model.text.endIndex)
        model.highlightTags()
        model.addAudio(recording.file, store: session.store)
        session.voice.reset()
        editorFocused = true
    }

    private func save(_ model: ComposerModel) {
        guard model.save(to: session.store) else { return }
        saved += 1
        dismiss()
    }

    private func close(_ model: ComposerModel) {
        session.voice.cancel()
        session.voice.reset()
        model.discardStaged(store: session.store)
        dismiss()
    }
}

/// MemoVisibility and Space, as opaque chips inside the sheet, plus a one-tap suggestion such as
/// “Share with Studio”.
private struct AudienceChips: View {
    @Bindable var model: ComposerModel
    @Environment(AccountSession.self) private var session

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Visibility", selection: $model.visibility) {
                        ForEach(MemoVisibility.choices.filter { $0 != .space || model.space != nil }, id: \.self) { visibility in
                            Label(label(for: visibility), systemImage: visibility.systemImage).tag(visibility)
                        }
                    }
                } label: {
                    Label(label(for: model.visibility), systemImage: model.visibility.systemImage)
                }
                .buttonStyle(.chip)

                Menu {
                    Button {
                        model.setSpace(nil)
                    } label: {
                        Label("No Space", systemImage: model.space == nil ? "checkmark" : "square.dashed")
                    }
                    ForEach(session.store.profile.spaces, id: \.name) { space in
                        Button {
                            model.setSpace(space.name)
                        } label: {
                            Label(space.title, systemImage: model.space == space.name ? "checkmark" : "square.stack")
                        }
                    }
                } label: {
                    Label(session.space(named: model.space)?.title ?? "No Space", systemImage: "square.stack")
                }
                .buttonStyle(.chip)

                if let suggestion = model.suggestion, suggestion != model.visibility, suggestion != .space || model.space != nil {
                    Button {
                        withAnimation(.memosSpring) { model.applySuggestion() }
                    } label: {
                        Label(suggestionLabel(suggestion), systemImage: suggestion.systemImage)
                    }
                    .buttonStyle(.prominentChip)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .scrollClipDisabled()
    }

    private func label(for visibility: MemoVisibility) -> String {
        if visibility == .space, let title = session.space(named: model.space)?.title {
            return "\(title) members"
        }
        return visibility.label
    }

    private func suggestionLabel(_ visibility: MemoVisibility) -> String {
        switch visibility {
        case .space: "Share with \(session.space(named: model.space)?.title ?? "Space")"
        case .protected: "Share with everyone signed in"
        case .public: "Make public"
        default: "Make \(visibility.label.lowercased())"
        }
    }
}

/// Attachments and the place, in a row above the chips, each removable.
private struct AttachmentStrip: View {
    @Bindable var model: ComposerModel
    @Environment(AccountSession.self) private var session

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let location = model.location {
                    chip {
                        Label(location.placeholder, systemImage: "mappin.and.ellipse")
                            .font(.subheadline)
                            .padding(.horizontal, 10)
                            .frame(height: 64)
                    } remove: {
                        withAnimation(.memosSpring) { model.location = nil }
                    }
                }
                ForEach(model.attachments, id: \.name) { attachment in
                    chip {
                        if attachment.isImage {
                            AttachmentImage(attachment: attachment)
                                .frame(width: 64, height: 64)
                        } else {
                            VStack(spacing: 4) {
                                Image(systemName: attachment.systemImage)
                                Text(attachment.filename)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .foregroundStyle(.ink2)
                            .frame(width: 88, height: 64)
                        }
                    } remove: {
                        model.remove(attachment, store: session.store)
                    }
                }
                if model.isLocating {
                    ProgressView().frame(width: 64, height: 64)
                }
            }
            .padding(.top, 6)
        }
        .scrollClipDisabled()
    }

    private func chip<Content: View>(@ViewBuilder content: () -> Content, remove: @escaping () -> Void) -> some View {
        content()
            .foregroundStyle(.ink)
            .background(.paper2)
            .clipShape(.rect(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .offset(x: 6, y: -6)
                .accessibilityLabel("Remove")
            }
    }
}

/// Shown at the top of the composer while a voice memo records or transcribes.
struct VoiceStatus: View {
    let recorder: VoiceRecorder
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch recorder.phase {
            case .recording:
                Waveform(levels: recorder.levels)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let started = recorder.startedAt {
                    Text(started, style: .timer)
                        .font(.metadata.monospacedDigit())
                        .foregroundStyle(.ink2)
                }
                Button("Stop", systemImage: "stop.fill", action: onStop)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
            case .transcribing:
                ProgressView()
                Text("Transcribing…")
                    .font(.metadata)
                    .foregroundStyle(.ink2)
                Spacer()
            case .failed(let message):
                Label(message, systemImage: "mic.slash")
                    .font(.metadata)
                    .foregroundStyle(.danger)
            default:
                EmptyView()
            }
        }
        .frame(minHeight: 36)
    }
}
