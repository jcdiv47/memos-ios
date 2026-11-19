import SwiftUI

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

/// How far a pressed control dims and shrinks. Shared so every custom button feels the same
/// under the finger.
enum Press {
    static let opacity = 0.6
    static let scale = 0.97
    /// A single emoji or symbol is small enough that 0.97 reads as nothing.
    static let glyphScale = 0.85
}

/// A lone emoji or symbol that shrinks under the finger, such as a reaction in the picker, and
/// springs back on release. Reduce Motion dims it instead.
struct GlyphPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? Press.glyphScale : 1)
            .opacity(configuration.isPressed && reduceMotion ? Press.opacity : 1)
            .animation(configuration.isPressed ? .memosPress : .reactionPop, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlyphPressStyle {
    static var glyphPress: GlyphPressStyle { GlyphPressStyle() }
}

/// Zooms out of `sourceID` and back into it, or uses the system transition when Reduce Motion is
/// on or nothing on screen opened it (a link, an intent).
struct ZoomTransition: ViewModifier {
    let sourceID: String?
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if let sourceID, !reduceMotion {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content.navigationTransition(.automatic)
        }
    }
}

extension View {
    /// Marks the view as what a zoom grows out of, where there's a namespace to zoom in.
    @ViewBuilder
    func matchedTransitionSource(id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Pushes and sheets grow out of the control that opened them, never from the middle of the
    /// screen: pair with `matchedTransitionSource(id:in:)` on the trigger.
    func zoomTransition(from sourceID: String?, in namespace: Namespace.ID) -> some View {
        modifier(ZoomTransition(sourceID: sourceID, namespace: namespace))
    }
}

/// The controls the app-wide sheets grow out of, for sheets that more than one control can open.
/// A memo's card is a source too, under the memo's name, for editing it.
enum SheetSource {
    /// The capture field in the bottom bar: the composer.
    static let captureField = "sheet.captureField"
    /// “Capture a Thought” on an empty timeline.
    static let emptyTimeline = "sheet.emptyTimeline"
    /// The “…” menu in the timeline's title row: Inbox and Settings.
    static let accountMenu = "sheet.accountMenu"
    /// Settings in the iPad sidebar.
    static let sidebarSettings = "sheet.sidebarSettings"
    /// The “…” menu of a saved view: a new memo in the view.
    static let viewMenu = "sheet.viewMenu"
    /// The “…” menu of a memo's detail: editing it.
    static let detailMenu = "sheet.detailMenu"
}
