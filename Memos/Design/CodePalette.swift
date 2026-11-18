import MemosCore
import SwiftUI

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
