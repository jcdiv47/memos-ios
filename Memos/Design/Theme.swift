import MemosCore
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

/// Colours for highlighted code, drawn on Paper 2. Each passes 4.5:1 there in light and dark,
/// and 7:1 with Increase Contrast. They resolve at draw time like the asset colours, so a cached
/// highlighted block stays right when the appearance changes.
enum CodePalette {
    static func color(_ kind: SyntaxTokenKind) -> Color {
        switch kind {
        case .keyword: keyword
        case .type: type
        case .string: string
        case .number: number
        case .comment: comment
        case .attribute: attribute
        case .tag: tag
        case .property, .variable: property
        case .punctuation: punctuation
        }
    }

    private static let keyword = dynamic(light: 0x9B2393, dark: 0xFF7AB2, lightHigh: 0x7A1A73, darkHigh: 0xFFA3CA)
    private static let type = dynamic(light: 0x703DAA, dark: 0xDABAFF, lightHigh: 0x5A2E8C, darkHigh: 0xE8D4FF)
    private static let string = dynamic(light: 0xC41A16, dark: 0xFF8170, lightHigh: 0x9A120F, darkHigh: 0xFFA597)
    private static let number = dynamic(light: 0x1C00CF, dark: 0xD9C97C, lightHigh: 0x1700A8, darkHigh: 0xEADF9F)
    private static let comment = dynamic(light: 0x5D6C79, dark: 0x7F8C98, lightHigh: 0x414C55, darkHigh: 0xA9B4BE)
    private static let attribute = dynamic(light: 0x815F03, dark: 0xCC9768, lightHigh: 0x634802, darkHigh: 0xE0B892)
    private static let tag = dynamic(light: 0x0F68A0, dark: 0x41A1C0, lightHigh: 0x0B4F79, darkHigh: 0x7CC8E2)
    private static let property = dynamic(light: 0x2F6A70, dark: 0x67B7A4, lightHigh: 0x24555A, darkHigh: 0x93D3C3)
    /// Ink 2, and Ink with Increase Contrast, where structure shouldn't recede.
    private static let punctuation = dynamic(light: 0x6B6961, dark: 0x9A9FA5, lightHigh: 0x242011, darkHigh: 0xE9E8E4)

    private static func dynamic(light: UInt32, dark: UInt32, lightHigh: UInt32, darkHigh: UInt32) -> Color {
        Color(uiColor: UIColor { @Sendable traits in
            let high = traits.accessibilityContrast == .high
            let hex = traits.userInterfaceStyle == .dark ? (high ? darkHigh : dark) : (high ? lightHigh : light)
            return UIColor(
                red: CGFloat(hex >> 16 & 0xFF) / 255,
                green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
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
            .background(prominent ? Color.memosBlue.opacity(0.12) : Color.well, in: .capsule)
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
            .background(.well, in: .circle)
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
