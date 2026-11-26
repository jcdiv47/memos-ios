import MemosCore
import SwiftUI

/// Colours for highlighted code, drawn on Paper 2. Each passes 4.5:1 there in light and dark,
/// and 7:1 with Increase Contrast. They're plain colours for one appearance rather than dynamic
/// ones: a block has a run per token, and resolving a dynamic colour for every run made opening
/// a memo full of code noticeably slower. ``MarkdownCache/code(_:language:appearance:)`` keeps a
/// highlighted block per appearance, so it still changes with light, dark and Increase Contrast.
enum CodePalette {
    /// What the colours depend on.
    struct Appearance: Hashable {
        var dark: Bool
        var highContrast: Bool

        init(_ colorScheme: ColorScheme, _ contrast: ColorSchemeContrast) {
            dark = colorScheme == .dark
            highContrast = contrast == .increased
        }
    }

    static func color(_ kind: SyntaxTokenKind, in appearance: Appearance) -> Color {
        let shades = switch kind {
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
        let hex = appearance.dark
            ? (appearance.highContrast ? shades.darkHigh : shades.dark)
            : (appearance.highContrast ? shades.lightHigh : shades.light)
        return Color(
            red: Double(hex >> 16 & 0xFF) / 255,
            green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    private typealias Shades = (light: UInt32, dark: UInt32, lightHigh: UInt32, darkHigh: UInt32)

    private static let keyword: Shades = (0x9B2393, 0xFF7AB2, 0x7A1A73, 0xFFA3CA)
    private static let type: Shades = (0x703DAA, 0xDABAFF, 0x5A2E8C, 0xE8D4FF)
    private static let string: Shades = (0xC41A16, 0xFF8170, 0x9A120F, 0xFFA597)
    private static let number: Shades = (0x1C00CF, 0xD9C97C, 0x1700A8, 0xEADF9F)
    private static let comment: Shades = (0x5D6C79, 0x7F8C98, 0x414C55, 0xA9B4BE)
    private static let attribute: Shades = (0x815F03, 0xCC9768, 0x634802, 0xE0B892)
    private static let tag: Shades = (0x0F68A0, 0x41A1C0, 0x0B4F79, 0x7CC8E2)
    private static let property: Shades = (0x2F6A70, 0x67B7A4, 0x24555A, 0x93D3C3)
    /// Ink 2, and Ink with Increase Contrast, where structure shouldn't recede.
    private static let punctuation: Shades = (0x6B6961, 0x9A9FA5, 0x242011, 0xE9E8E4)
}
