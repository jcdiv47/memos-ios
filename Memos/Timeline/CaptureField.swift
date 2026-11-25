import MemosCore
import SwiftUI

/// The floating glass bar at the bottom of the timeline and Library: the capture pill and Search.
/// Placed with `.safeAreaInset(edge: .bottom)` (matching `DetailBar`) rather than
/// `ToolbarItem(placement: .bottomBar)` so each pushed screen owns its bottom bar and pushing a
/// memo never toggles `UINavigationController`'s shared bottom toolbar.
struct CaptureBar: View {
    var source = SheetSource.captureField
    let zoom: Namespace.ID
    var onSearch: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: Spacing.l) {
            HStack(spacing: Spacing.l) {
                CaptureField(source: source)
                    .frame(minHeight: FloatingBar.height)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Radius.panel))
                    .matchedTransitionSource(id: source, in: zoom)

                Button(action: onSearch) {
                    Image(icon: .search)
                        .font(.barSymbol)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(.ink)
                        .frame(width: FloatingBar.height, height: FloatingBar.height)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Search")
            }
        }
        .padding(.horizontal, Metrics.screenInset)
        .padding(.bottom, Spacing.m)
        .readableWidth()
    }
}

/// The capture pill inside ``CaptureBar``. Tap to write; long-press the mic to dictate, and the
/// field stretches into a live waveform while recording.
struct CaptureField: View {
    /// What the composer grows out of: this field's ``SheetSource``.
    var source = SheetSource.captureField

    @Environment(AccountSession.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoldingMic = false

    private static let holdDuration = 0.25

    var body: some View {
        let voice = session.voice
        HStack(spacing: Spacing.l) {
            if voice.isRecording {
                Button {
                    voice.cancel()
                    voice.reset()
                } label: {
                    Image(icon: .x)
                        .font(.barSymbol)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(.ink)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.glyphPress)
                .accessibilityLabel("Cancel recording")

                Waveform(levels: voice.levels)
                    .frame(maxWidth: .infinity)

                Button {
                    stopRecording()
                } label: {
                    Image(icon: .squareFill)
                        .font(.barSymbol)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(.memosBlue)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.glyphPress)
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
                                Image(icon: .pencilLine)
                                    .foregroundStyle(.memosBlue)
                            }
                        } else {
                            Text("Capture a thought…")
                        }
                    }
                    .foregroundStyle(.ink2)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? Spacing.m : 0)
                    .frame(maxWidth: .infinity, minHeight: FloatingBar.height, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(PromptPressStyle())
                .accessibilityHidden(true)

                // A full 44 pt tap target inside the 48 pt capsule.
                Image(icon: .mic)
                    .font(.barSymbol)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(isHoldingMic ? Color.memosBlue : Color.ink2)
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
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
        .padding(.leading, voice.isRecording ? Spacing.xs : Spacing.xl)
        .padding(.trailing, Spacing.xs)
        .frame(maxWidth: .infinity, minHeight: FloatingBar.height)
        .contentShape(.rect(cornerRadius: Radius.panel))
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
            .opacity(configuration.isPressed ? Press.labelOpacity : 1)
            .animation(.memosPress, value: configuration.isPressed)
    }
}
