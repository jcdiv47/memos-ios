import SwiftMath
import SwiftUI
import UIKit

/// TeX typeset by SwiftMath, cropped to the ink and drawn in black so it takes the text's
/// colour as a template image.
struct TypesetMath {
    let image: CGImage
    let scale: CGFloat
    /// How far the formula reaches below its baseline, in points.
    let descent: CGFloat
    let tex: String

    /// The formula as an image that sits on the text's baseline and takes its colour, read by
    /// VoiceOver as its TeX.
    var inlineText: Text {
        Text(Image(image, scale: scale, orientation: .up, label: Text(verbatim: tex)).renderingMode(.template))
            .baselineOffset(-descent)
    }

    var view: some View {
        Image(image, scale: scale, orientation: .up, label: Text(verbatim: tex)).renderingMode(.template)
    }
}

enum MathTypesetter {
    /// Latin Modern sets smaller than SF at the same size; this matches their x-heights, as
    /// the web's KaTeX does with its 1.21em.
    static let sizeRatio: CGFloat = 1.15

    /// Nil when SwiftMath can't set the TeX faithfully, so the source is shown instead: a
    /// syntax error, a command it doesn't know, or a character it would silently leave out.
    static func typeset(_ tex: String, fontSize: CGFloat, display: Bool) -> TypesetMath? {
        guard !tex.allSatisfy(\.isWhitespace), isSafe(tex) else { return nil }
        let size = fontSize * sizeRatio
        // Room above and below for SwiftMath's centring of very short formulas, cropped off below.
        let inset = size / 4
        var math = MathImage(latex: tex, fontSize: size, textColor: .black, labelMode: display ? .display : .text, textAlignment: .left)
        math.contentInsets = UIEdgeInsets(top: inset, left: 1, bottom: inset, right: 1)
        let (error, rendered, layout) = math.asImage()
        guard error == nil, let rendered, let layout, let full = rendered.cgImage, rendered.size.width > 2 else { return nil }

        // Where SwiftMath put the baseline, measured from the bottom (MathImage.layoutImage).
        let height = layout.ascent + layout.descent
        let baseline = (rendered.size.height - 2 * inset - max(height, size / 2)) / 2 + layout.descent + inset
        let scale = rendered.scale
        let top = ((rendered.size.height - baseline - layout.ascent) * scale).rounded(.down)
        let bottom = ((rendered.size.height - baseline + layout.descent) * scale).rounded(.up)
        let crop = CGRect(x: 0, y: max(0, top), width: CGFloat(full.width), height: min(CGFloat(full.height), bottom) - max(0, top))
        guard crop.height > 0, crop.height / scale <= fontSize * 16, crop.width / scale <= 4000,
              let image = full.cropping(to: crop)
        else { return nil }
        let descent = (bottom - ((rendered.size.height - baseline) * scale)) / scale
        return TypesetMath(image: image, scale: scale, descent: descent, tex: tex)
    }

    /// Outside `\text{…}`, SwiftMath drops any character it has no atom for without an error,
    /// so `x + 日本` would show as `x +`, and `#tag` as `tag` (KaTeX refuses a bare `#`). And
    /// `\sqrt[` with a stray `}` before its `]` trips an assertion in SwiftMath's parser, which
    /// crashes debug builds.
    static func isSafe(_ tex: String) -> Bool {
        var index = tex.startIndex
        // Brace depth inside `\text{`, or nil outside it.
        var textDepth: Int?
        while index < tex.endIndex {
            let character = tex[index]
            if character == "\\" {
                let name = tex[tex.index(after: index)...].prefix { $0.isASCII && $0.isLetter }
                let after = tex.index(index, offsetBy: 1 + name.count, limitedBy: tex.endIndex) ?? tex.endIndex
                if textDepth == nil, name == "text", after < tex.endIndex, tex[after] == "{" {
                    textDepth = 0
                    index = after
                    continue
                }
                if name == "sqrt", after < tex.endIndex, tex[after] == "[", !closesOptionalArgument(tex, from: tex.index(after: after)) {
                    return false
                }
                // Skip the command, or the one escaped character after a backslash.
                index = name.isEmpty ? (tex.index(index, offsetBy: 2, limitedBy: tex.endIndex) ?? tex.endIndex) : after
                continue
            }
            if let depth = textDepth {
                if character == "{" { textDepth = depth + 1 }
                if character == "}" { textDepth = depth == 1 ? nil : depth - 1 }
            } else if character == "#" || (!character.isASCII && MTMathAtomFactory.atom(forCharacter: character) == nil) {
                return false
            }
            index = tex.index(after: index)
        }
        return true
    }

    /// Whether the `[…]` starting at `start` reaches its `]` without closing a brace it didn't open.
    private static func closesOptionalArgument(_ tex: String, from start: String.Index) -> Bool {
        var depth = 0
        for character in tex[start...] {
            switch character {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth < 0 { return false }
            case "]" where depth == 0: return true
            default: break
            }
        }
        return true
    }
}
