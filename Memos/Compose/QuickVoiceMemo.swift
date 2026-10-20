import MemosCore
import SwiftUI

/// The Voice memo control and the Action button: record, then save straight away. The
/// audience is never shown, so the memo is Private.
struct QuickVoiceMemoSheet: View {
    @Environment(AccountSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var saved = 0

    var body: some View {
        let voice = session.voice
        VStack(spacing: 18) {
            (voice.phase == .transcribing ? Text("Transcribing…") : Text("Recording a private memo"))
                .font(.headline)
                .foregroundStyle(.ink)
            switch voice.phase {
            case .recording:
                Waveform(levels: voice.levels)
                    .frame(height: 30)
                if let started = voice.startedAt {
                    Text(started, style: .timer)
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(.ink2)
                }
            case .transcribing:
                ProgressView()
                Text(voice.transcript)
                    .font(.callout)
                    .foregroundStyle(.ink2)
                    .lineLimit(3)
            case .failed(let message):
                Text(message).foregroundStyle(.danger)
            default:
                ProgressView()
            }
            HStack(spacing: 14) {
                Button("Cancel", role: .cancel) {
                    voice.cancel()
                    voice.reset()
                    dismiss()
                }
                .buttonStyle(.glass)
                Button("Save", systemImage: "stop.fill") {
                    Task { await save() }
                }
                .buttonStyle(.glassProminent)
                .tint(.memosBlue)
                .disabled(voice.phase != .recording)
            }
        }
        .padding(24)
        .presentationDetents([.height(280)])
        .interactiveDismissDisabled()
        .sensoryFeedback(.success, trigger: saved)
        .task { await voice.start() }
    }

    private func save() async {
        guard let recording = await session.voice.stop(client: session.client, online: session.isOnline) else { return }
        var attachments: [Attachment] = []
        if let data = try? Data(contentsOf: recording.file),
           let staged = try? session.store.stageUpload(data: data, filename: recording.file.lastPathComponent, mimeType: "audio/mp4") {
            attachments.append(staged)
        }
        try? FileManager.default.removeItem(at: recording.file)
        let visibility = VisibilityRules.initial(defaultVisibility: session.defaultVisibility, origin: .silent(explicit: nil)).visibility
        session.store.create(MemoDraft(content: recording.transcript, visibility: visibility, attachments: attachments))
        session.voice.reset()
        saved += 1
        dismiss()
    }
}
