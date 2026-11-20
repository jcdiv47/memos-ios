import MemosCore
import SwiftUI

/// The middle of the bottom bar. Tap to write; long-press the mic to dictate, and the field
/// stretches into a live waveform while recording.
struct CaptureField: View {
    /// What the composer grows out of: this field's ``SheetSource``. Mark the toolbar item
    /// holding the field with the same id.
    var source = SheetSource.captureField
    /// The width the bar has for the field, from ``width(in:)``. The bottom bar sizes its items
    /// to their ideal width, so without one the field stays a short pill in the middle.
    var idealWidth: CGFloat?

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

                    // A full tap target, without making the field taller: the extra height hangs
                    // over the field's edges, and the trailing inset shrinks so the symbol stays put.
                    Image(systemName: "mic")
                        .foregroundStyle(isHoldingMic ? Color.memosBlue : Color.ink2)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .scaleEffect(isHoldingMic && !reduceMotion ? 1.2 : 1)
                        .contentShape(.rect)
                        .padding(.vertical, -Spacing.xxs)
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
            .padding(.trailing, voice.isRecording ? Spacing.m : Spacing.xxs)
            .frame(minWidth: 170, idealWidth: idealWidth ?? 230, maxWidth: .infinity, minHeight: 40)
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

    /// The field's width on a screen `width` wide: the bar's margins and the round Search button
    /// beside it taken away, and no wider than a readable column on an iPad.
    static func width(in width: CGFloat) -> CGFloat {
        let besideField = 2 * Metrics.screenInset + FloatingBar.height + Spacing.l
        return min(width, Metrics.readableWidth) - besideField
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
            .opacity(configuration.isPressed ? Press.labelOpacity : 1)
            .animation(.memosPress, value: configuration.isPressed)
    }
}
