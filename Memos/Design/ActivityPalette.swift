import SwiftUI

/// The activity grid's scale, shared by the Activity screen, the Library card and the widget.
/// Well for an empty day, then Activity 1 to 4: opaque colours whose lightness is spaced so
/// neighbouring levels sit about 1.7:1 apart, brighter with more memos in dark mode and darker
/// in light mode.
extension Color {
    static func activity(level: Int) -> Color {
        switch level {
        case ...0: .well
        case 1: .activity1
        case 2: .activity2
        case 3: .activity3
        default: .activity4
        }
    }
}
