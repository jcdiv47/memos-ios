import MemosCore
import SwiftUI
import UIKit

// The app's icons are Lucide's, built into custom symbols by `scripts/lucide-symbols.py`. These
// mirror SwiftUI's `systemImage:` initialisers, so an icon scales with its font, sits on the text
// baseline and works in menus, toolbars and swipe actions the way an SF Symbol does. Shortcuts
// and Siri still get SF Symbols: those show in the system's own UI.

extension Image {
    /// Decorative: VoiceOver would otherwise read the asset's name, “Lucide/eye-off”. A label
    /// beside it names it, or the control it's in carries an `accessibilityLabel`.
    init(icon: MemosCore.Lucide) {
        self.init(decorative: icon.assetName)
    }
}

extension UIImage {
    convenience init?(icon: MemosCore.Lucide) {
        self.init(named: icon.assetName)
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ titleKey: LocalizedStringKey, icon: MemosCore.Lucide) {
        self.init { Text(titleKey) } icon: { Image(icon: icon) }
    }

    @_disfavoredOverload
    init(_ resource: LocalizedStringResource, icon: MemosCore.Lucide) {
        self.init { Text(resource) } icon: { Image(icon: icon) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, icon: MemosCore.Lucide) {
        self.init { Text(title) } icon: { Image(icon: icon) }
    }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    init(_ titleKey: LocalizedStringKey, icon: MemosCore.Lucide, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(titleKey, icon: icon) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, icon: MemosCore.Lucide, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, icon: icon) }
    }
}

extension Menu where Label == SwiftUI.Label<Text, Image> {
    init(_ titleKey: LocalizedStringKey, icon: MemosCore.Lucide, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(titleKey, icon: icon) }
    }
}

extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    init(_ titleKey: LocalizedStringKey, icon: MemosCore.Lucide, description: Text? = nil) {
        self.init {
            SwiftUI.Label(titleKey, icon: icon)
        } description: {
            description
        }
    }
}
