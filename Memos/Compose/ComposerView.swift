import MemosCore
import PhotosUI
import SwiftUI

/// The composer: a sheet that sits on the keyboard. Who can see the memo sits under the title,
/// the text runs edge to edge below it, and one glass bar of formatting and capture actions
/// floats above the keys beside a button that lowers them. Save is the app's only tinted glass.
struct ComposerView: View {
    let request: ComposerRequest

    @Environment(AccountSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var model: ComposerModel?
    @State private var detent: PresentationDetent
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isPickingPhotos = false
    @State private var isImportingFiles = false
    @State private var isTakingPhoto = false
    @State private var isScanning = false
    @State private var confirmDiscard = false
    @State private var saved = 0
    @State private var editorFocused = false
    @State private var hasBegun = false

    init(request: ComposerRequest) {
        self.request = request
        // The keyboard pushes a medium sheet to full height, so a composer that opens typing
        // starts there instead of retargeting mid-presentation. Voice capture has no keyboard.
        var opensRecording = false
        if case .new(_, _, let record, let voiceMemo) = request.mode { opensRecording = record || voiceMemo }
        _detent = State(initialValue: opensRecording ? .medium : .large)
    }

    var body: some View {
        NavigationStack {
            if let model {
                content(model)
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        // Swiping the sheet away keeps the draft; only a recording would be lost.
        .interactiveDismissDisabled(isCapturingVoice)
        .sensoryFeedback(.success, trigger: saved)
        .onAppear {
            if model == nil { model = ComposerModel(request: request, session: session) }
        }
        .onDisappear { model?.keepDraft() }
    }

    private var isCapturingVoice: Bool {
        session.voice.phase == .recording || session.voice.phase == .transcribing
    }

    private var title: LocalizedStringResource {
        if case .edit = request.mode { return "Edit memo" }
        return "New memo"
    }

    @ViewBuilder
    private func content(_ model: ComposerModel) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            AudienceChips(model: model)

            if session.voice.phase != .idle && session.voice.phase != .finished {
                VoiceStatus(recorder: session.voice) {
                    Task { await finishRecording(model) }
                }
                .transition(.opacity)
            }

            MemoTextView(model: model, isFocused: $editorFocused)
                .overlay(alignment: .topLeading) {
                    if model.text.isEmpty {
                        Text("Capture a thought…")
                            .font(.memoBody)
                            .foregroundStyle(.ink2)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                // The text lines up with the chips above it.
                .padding(.horizontal, -5)

            if !model.attachments.isEmpty || model.location != nil || model.preparing > 0 || model.isLocating {
                AttachmentStrip(model: model)
                    .transition(.opacity)
            }

            if let error = model.error {
                Text(error)
                    .font(.metadata)
                    .foregroundStyle(.danger)
            } else if let notice = model.notice {
                Text(notice)
                    .font(.metadata)
                    .foregroundStyle(.ink2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        // Rows that come and go above and below the text ease the editor aside instead of
        // shoving it.
        .animation(.memosSpring, value: session.voice.phase)
        .animation(.memosSpring, value: model.preparing > 0 || model.isLocating)
        // In the sheet's own layout rather than a keyboard toolbar: the input accessory attaches
        // after the keyboard lands, so the bar popped in and the editor shrank a second time.
        .safeAreaBar(edge: .bottom) {
            FormattingBar(showsHideKeyboard: editorFocused) {
                // Suggestions take the formatting buttons' place while a tag is typed, so the
                // bar never changes height under the text.
                if model.tagSuggestions.isEmpty {
                    formattingActions(model)
                        .disabled(model.isComposing)
                        .transition(.opacity)
                } else {
                    TagSuggestions(tags: model.tagSuggestions) { model.completeTag($0) }
                        .transition(.opacity)
                }
                captureActions(model)
            } onHideKeyboard: {
                editorFocused = false
            }
            .animation(.memosFade, value: model.tagSuggestions.isEmpty)
            .animation(.memosFade, value: editorFocused)
        }
        .navigationTitle(Text(title))
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
                    .disabled(model.isEmpty || (model.editing != nil && !model.hasChanges) || isCapturingVoice)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .confirmationDialog("Discard this memo?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { discard(model) }
            Button("Keep Draft") { close(model) }
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
        .fullScreenCover(isPresented: $isTakingPhoto) {
            CameraPicker { image in
                isTakingPhoto = false
                if let image { Task { await model.addCameraPhoto(image, store: session.store) } }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $isScanning) {
            DocumentScanner { pages in
                isScanning = false
                Task { await model.addScan(pages, store: session.store) }
            }
            .ignoresSafeArea()
        }
        .task { await begin(model) }
    }

    @ViewBuilder
    private func formattingActions(_ model: ComposerModel) -> some View {
        Button { model.format(.taskList) } label: { Image(systemName: "checklist") }
            .accessibilityLabel("Task")
        Button { model.insertTag() } label: { Image(systemName: "number") }
            .accessibilityLabel("Tag")
        // Everything else, bold and lists included, lives in the menu so the bar stays one group
        // with room for the hide-keyboard button on a 402-point phone.
        Menu {
            ForEach(MarkdownFormat.menuSections, id: \.self) { formats in
                Section {
                    ForEach(formats, id: \.self) { format in
                        Button(format.title, systemImage: format.systemImage) { model.format(format) }
                    }
                }
            }
        } label: {
            Image(systemName: "textformat")
        }
        .accessibilityLabel("Format")
    }

    @ViewBuilder
    private func captureActions(_ model: ComposerModel) -> some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { isPickingPhotos = true }
            if CameraPicker.isAvailable {
                Button("Take Photo", systemImage: "camera") { isTakingPhoto = true }
            }
            if DocumentScanner.isSupported {
                Button("Scan Document", systemImage: "doc.viewfinder") { isScanning = true }
            }
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
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(session.voice.isRecording ? Text("Stop recording") : Text("Record voice memo"))
    }

    // MARK: Lifecycle

    private func begin(_ model: ComposerModel) async {
        // The task runs again when the camera's full-screen cover goes away; that's no new start.
        guard !hasBegun else { return }
        hasBegun = true
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
        let before = model.text
        guard let recording = await session.voice.stop(client: session.client, online: session.isOnline) else { return }
        apply(recording, to: model, after: before)
    }

    private func waitForTranscript(_ model: ComposerModel) async {
        // A restored draft stays ahead of the transcript.
        let before = model.text
        while session.voice.phase == .transcribing || session.voice.phase == .recording {
            let combined = ComposerModel.joining(session.voice.transcript, to: before)
            if model.text != combined { model.replaceText(combined) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let recording = session.voice.lastRecording {
            apply(recording, to: model, after: before)
        }
    }

    private func apply(_ recording: VoiceRecorder.Recording, to model: ComposerModel, after text: String) {
        model.replaceText(ComposerModel.joining(recording.transcript, to: text))
        model.addAudio(recording.file, store: session.store)
        session.voice.reset()
        editorFocused = true
    }

    private func save(_ model: ComposerModel) {
        guard model.save(to: session.store) else { return }
        saved += 1
        dismiss()
    }

    /// Closes the composer; the draft stays for next time.
    private func close(_ model: ComposerModel) {
        session.voice.cancel()
        session.voice.reset()
        model.keepDraft()
        dismiss()
    }

    private func discard(_ model: ComposerModel) {
        session.voice.cancel()
        session.voice.reset()
        model.discard(store: session.store)
        dismiss()
    }
}

/// Your tags matching the one being typed, in the formatting bar. Tapping one finishes the tag.
private struct TagSuggestions: View {
    let tags: [String]
    var onSelect: (String) -> Void

    var body: some View {
        ForEach(tags, id: \.self) { tag in
            Button { onSelect(tag) } label: {
                Text(verbatim: "#\(tag)")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .buttonStyle(TagSuggestionStyle())
            .accessibilityLabel(Text("Add tag \(tag)"))
        }
    }
}

private struct TagSuggestionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.tint)
            .padding(.horizontal, 10)
            .frame(minHeight: 48)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

/// The formatting, attach and record buttons as one glass group pinned to the bottom of the
/// sheet, so they ride up with the keyboard in the same animation, and a round button beside
/// them that lowers the keyboard while it's up.
private struct FormattingBar<Actions: View>: View {
    var showsHideKeyboard: Bool
    @ViewBuilder var actions: Actions
    var onHideKeyboard: () -> Void

    var body: some View {
        GlassEffectContainer {
            HStack {
                group {
                    // Scrolls when it doesn't fit: a narrow phone, large text or many tags.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 0) { actions }
                        ScrollView(.horizontal) {
                            HStack(spacing: 0) { actions }
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                Spacer(minLength: 8)
                if showsHideKeyboard {
                    Button(action: onHideKeyboard) {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                    .buttonStyle(BarButtonStyle())
                    .frame(width: 48)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Hide Keyboard")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
        }
        .font(.title3)
        .tint(.memosBlue)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
            .buttonStyle(BarButtonStyle())
            .menuStyle(.button)
            .padding(.horizontal, 6)
            .glassEffect(.regular.interactive(), in: .capsule)
    }
}

private struct BarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.tint)
            .frame(width: 44, height: 48)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.5 : 1)
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
                        withAnimation(.memosSpring) { model.setSpace(nil) }
                    } label: {
                        Label("No Space", systemImage: model.space == nil ? "checkmark" : "square.dashed")
                    }
                    ForEach(session.store.profile.spaces, id: \.name) { space in
                        Button {
                            // Animated, so the suggestion it may offer grows in.
                            withAnimation(.memosSpring) { model.setSpace(space.name) }
                        } label: {
                            Label(space.title, systemImage: model.space == space.name ? "checkmark" : "square.stack")
                        }
                    }
                } label: {
                    Label(session.space(named: model.space)?.title ?? String(localized: "No Space"), systemImage: "square.stack")
                }
                .buttonStyle(.chip)

                if let suggestion = model.suggestion, suggestion != model.visibility, suggestion != .space || model.space != nil {
                    Button {
                        withAnimation(.memosSpring) { model.applySuggestion() }
                    } label: {
                        Label(suggestionLabel(suggestion), systemImage: suggestion.systemImage)
                    }
                    .buttonStyle(.prominentChip)
                    // Grows out of the chips beside it, never from nothing.
                    .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                }
            }
        }
        .scrollClipDisabled()
        // The row sits right under the navigation bar, which would otherwise treat it as the
        // content scrolling beneath it and draw a band of blur behind the title.
        .scrollEdgeEffectHidden(true, for: .top)
    }

    private func label(for visibility: MemoVisibility) -> String {
        if visibility == .space, let title = session.space(named: model.space)?.title {
            return String(localized: "\(title) members", comment: "The Space visibility chip in the composer: only members of the named Space can read the memo.")
        }
        return visibility.label
    }

    private func suggestionLabel(_ visibility: MemoVisibility) -> String {
        switch visibility {
        case .space:
            if let title = session.space(named: model.space)?.title {
                String(localized: "Share with \(title)", comment: "A composer suggestion that makes the memo visible to the members of the named Space.")
            } else {
                String(localized: "Share with Space", comment: "A composer suggestion that makes the memo visible to the members of its Space, when the Space's name isn't known.")
            }
        case .protected: String(localized: "Share with everyone signed in")
        case .public: String(localized: "Make public")
        default: String(localized: "Make private")
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
                if model.isLocating || model.preparing > 0 {
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
            .background(.well)
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
