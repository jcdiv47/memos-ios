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
