import Foundation

/// Where a new memo is being captured from. Each starts from a different visibility.
public enum CaptureOrigin: Equatable, Sendable {
    /// The capture field or the New memo button, with the title menu's current Space.
    case timeline(space: String?)
    /// A saved view or search whose filter pins one visibility, such as `visibility == "PUBLIC"`.
    case view(space: String?, visibility: MemoVisibility)
    /// The share sheet or a widget: the composer opens with no Space.
    case shareSheet
    /// No composer at all: the Voice memo control, the Action button, or a Shortcut. `explicit`
    /// is a visibility the Shortcut passed.
    case silent(explicit: MemoVisibility?)
}

/// How a new memo starts: never more open than the person chose.
public struct InitialVisibility: Equatable, Sendable {
    public var visibility: MemoVisibility
    /// A one-tap alternative offered as a chip, such as “Share with Studio”, or nil.
    public var suggestion: MemoVisibility?
}

public enum VisibilityRules {
    /// The visibility a new memo starts with, from the `memo_visibility` setting (Private when
    /// never set) and where the capture began. Writing into a Space can only narrow the
    /// default; nothing here ever widens it.
    public static func initial(defaultVisibility: MemoVisibility?, origin: CaptureOrigin) -> InitialVisibility {
        let base = normalizedDefault(defaultVisibility)
        switch origin {
        case .timeline(nil), .shareSheet:
            return InitialVisibility(visibility: base, suggestion: nil)

        case .timeline(.some):
            return inSpace(base)

        case .view(let space, let visibility):
            var result = space == nil ? InitialVisibility(visibility: base, suggestion: nil) : inSpace(base)
            // Suggest the view's visibility instead of applying it, as the web does. SPACE only
            // makes sense when the memo is going into a Space.
            if visibility != result.visibility, visibility != .space || space != nil {
                result.suggestion = visibility
            }
            return result

        case .silent(let explicit):
            return InitialVisibility(visibility: explicit ?? .private, suggestion: nil)
        }
    }

    /// Visibility after the Space is removed from a draft: Space visibility means nothing
    /// without a Space, so it falls back to Private.
    public static func afterRemovingSpace(_ visibility: MemoVisibility) -> MemoVisibility {
        visibility == .space ? .private : visibility
    }

    /// Visibility after a draft moves into a Space: Protected and Public narrow to Space, the
    /// same rule as capturing inside a Space.
    public static func afterAddingSpace(_ visibility: MemoVisibility) -> MemoVisibility {
        switch visibility {
        case .protected, .public: .space
        default: visibility
        }
    }

    private static func inSpace(_ base: MemoVisibility) -> InitialVisibility {
        switch base {
        case .private:
            // Placing a memo in a Space doesn't share it. One tap does.
            InitialVisibility(visibility: .private, suggestion: .space)
        default:
            // Only the Space's members can read it; widening back to the default is one tap.
            InitialVisibility(visibility: .space, suggestion: base == .space ? nil : base)
        }
    }

    private static func normalizedDefault(_ visibility: MemoVisibility?) -> MemoVisibility {
        switch visibility {
        case .protected?: .protected
        case .public?: .public
        default: .private
        }
    }
}
