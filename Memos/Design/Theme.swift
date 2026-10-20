import SwiftUI

/// Type from the design's token sheet. New York stands in for the web wordmark's Source Serif
/// and is used only for titles, so the timeline reads as notes rather than a magazine.
extension Font {
    /// New York Bold, 34 pt: the large title.
    static let largeTitleSerif = Font.system(.largeTitle, design: .serif).bold()
    /// New York Semibold, 20 pt, from a memo's first heading.
    static let memoTitle = Font.system(.title3, design: .serif).weight(.semibold)
    /// SF Pro Text, 17 pt, Dynamic Type body.
    static let memoBody = Font.body
    /// SF Pro, 13 pt, drawn in Ink 2.
    static let metadata = Font.footnote
    /// SF Mono, 15 pt.
    static let memoCode = Font.system(.subheadline, design: .monospaced)
}

enum Metrics {
    static let cardRadius: CGFloat = 16
    static let cardPadding: CGFloat = 14
    static let timelineInset: CGFloat = 16
}

/// The opaque surface every memo is drawn on: paper for what you wrote, glass only for what you do.
struct CardBackground: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(.card, in: .rect(cornerRadius: Metrics.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                    .strokeBorder(contrast == .increased ? .ink2 : .hairline, lineWidth: contrast == .increased ? 1 : 0.5)
            }
    }
}

extension View {
    func cardBackground() -> some View { modifier(CardBackground()) }
}

/// A small opaque chip, used for visibility and Space inside glass surfaces: no glass on glass.
struct ChipStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.memosBlue : Color.ink)
            .background(prominent ? Color.memosBlue.opacity(0.12) : Color.paper2, in: .capsule)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.memosPress, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ChipStyle {
    static var chip: ChipStyle { ChipStyle() }
    static var prominentChip: ChipStyle { ChipStyle(prominent: true) }
}

/// The springs from the motion table. Everything can be interrupted; bounce only where something
/// lands on purpose.
extension Animation {
    /// Capture field → composer, and most layout changes: 0.35 s response, no bounce.
    static let memosSpring = Animation.spring(response: 0.35, dampingFraction: 1)
    /// The chosen reaction popping in: 0.3 s response at 0.8 damping.
    static let reactionPop = Animation.spring(response: 0.3, dampingFraction: 0.8)
    /// Something arriving in place, like a downloaded photo: 0.2 s on a strong ease-out.
    static let memosFade = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
    /// A press acknowledged under the finger: 0.16 s on the same curve.
    static let memosPress = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
}

/// A letter avatar, or the user's picture once loaded.
struct Avatar: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
            .foregroundStyle(.ink)
            .frame(width: size, height: size)
            .background(.paper2, in: .circle)
            .accessibilityHidden(true)
    }
}

/// Zooms out of `sourceID`, or cross-fades when Reduce Motion is on.
struct ZoomTransition: ViewModifier {
    let sourceID: String
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content.navigationTransition(.automatic)
        } else {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        }
    }
}

extension View {
    func zoomTransition(from sourceID: String, in namespace: Namespace.ID) -> some View {
        modifier(ZoomTransition(sourceID: sourceID, namespace: namespace))
    }
}
