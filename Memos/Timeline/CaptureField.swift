import MemosCore
import SwiftUI

/// The middle of the bottom bar. Tap to write; long-press the mic to dictate, and the field
/// stretches into a live waveform while recording.
struct CaptureField: View {
    /// What the composer grows out of: this field's ``SheetSource``. Mark the toolbar item
    /// holding the field with the same id.
    var source = SheetSource.captureField

    @Environment(AccountSession.self) private var session
    @Namespace private var glass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoldingMic = false

    private static let holdDuration = 0.25

    var body: some View {
        let voice = session.voice
        GlassEffectContainer(spacing: Spacing.m) {
            HStack(spacing: Spacing.l) {
                if voice.isRecording {
                    Button {
                        voice.cancel()
                        voice.reset()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel recording")

                    Waveform(levels: voice.levels)
                        .frame(maxWidth: .infinity)
                        .glassEffectID("field", in: glass)

                    Button {
                        stopRecording()
                    } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.memosBlue)
                    }
                    .accessibilityLabel("Stop and transcribe")
                } else {
                    // A button, so the prompt answers the finger before the sheet rises.
                    Button {
                        session.capture(from: source)
                    } label: {
                        // Grows taller at large text sizes instead of truncating.
                        Group {
                            if session.drafts.hasNewMemoDraft {
                                Label {
                                    Text("Continue draft")
                                } icon: {
                                    Image(systemName: "pencil.line")
                                        .foregroundStyle(.memosBlue)
                                }
                            } else {
                                Text("Capture a thought…")
                            }
                        }
                        .foregroundStyle(.ink2)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(PromptPressStyle())
                    .accessibilityHidden(true)
                    .glassEffectID("field", in: glass)

                    Image(systemName: "mic")
                        .foregroundStyle(isHoldingMic ? Color.memosBlue : Color.ink2)
                        .frame(width: 30, height: 30)
                        .scaleEffect(isHoldingMic && !reduceMotion ? 1.2 : 1)
                        .contentShape(.rect)
                        .onLongPressGesture(minimumDuration: Self.holdDuration) {
                            Task { await voice.start() }
                        } onPressingChanged: { pressing in
                            // The mic grows for exactly as long as the hold takes; letting go snaps back.
                            withAnimation(pressing ? .easeOut(duration: Self.holdDuration) : .memosSpring) {
                                isHoldingMic = pressing
                            }
                        }
                        .accessibilityLabel("Dictate")
                        .accessibilityHint("Records a voice memo")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { Task { await voice.start() } }
                }
            }
            .padding(.leading, Spacing.xl)
            .padding(.trailing, Spacing.m)
            .frame(minWidth: 170, idealWidth: 230, maxWidth: .infinity, minHeight: 40)
        }
        .contentShape(.capsule)
        .onTapGesture {
            if !voice.isRecording { session.capture(from: source) }
        }
        .animation(.memosSpring, value: voice.isRecording)
        .animation(.memosFade, value: session.drafts.hasNewMemoDraft)
        .sensoryFeedback(trigger: voice.isRecording) { _, recording in
            recording ? .start : .stop
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.drafts.hasNewMemoDraft ? Text("Continue draft") : Text("Capture a thought"))
        .accessibilityIdentifier("captureField")
        .accessibilityAddTraits(.isButton)
    }

    private func stopRecording() {
        // The composer opens right away; the transcript streams into it.
        session.composer = ComposerRequest(mode: .new(origin: .timeline(space: session.selectedSpace), text: "", record: false, voiceMemo: true), source: source)
        Task { _ = await session.voice.stop(client: session.client, online: session.isOnline) }
    }
}

/// The capture prompt dims under the finger, on the press curve, like a toolbar button's label.
private struct PromptPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            .animation(.memosPress, value: configuration.isPressed)
    }
}
