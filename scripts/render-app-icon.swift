#!/usr/bin/env swift
// Renders the app icon's default, dark and tinted PNGs into the asset catalog, and the same mark at
// sign-in size into the AppMark image set beside it:
//   swift scripts/render-app-icon.swift
// The mark is 犬, "dog", as oracle-bone script wrote it: stood on end, head at the top and barking,
// back arched, two legs reaching left and the tail curled up. Each stroke is a brush line whose width
// changes along its length: it presses in heavy and lifts off light. The design lives in Paper, on the
// "App icon" page of the Memos for iPhone file.

import AppKit
import CoreGraphics

let size = 1024
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Memos/Resources/Assets.xcassets/AppIcon.appiconset")
let markOutput = output.deletingLastPathComponent().appendingPathComponent("AppMark.imageset")
/// Sign-in shows the mark at 72 pt.
let markPoints = 72

typealias RGB = (CGFloat, CGFloat, CGFloat)

func color(_ c: RGB, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha)
}

func hex(_ value: UInt32) -> RGB {
    (CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
}

// MARK: - The glyph

/// A stroke's centreline as cubic Bézier segments, and its width (before scaling) at points along it,
/// where 0 is where the brush lands and 1 is where it lifts.
struct Stroke {
    var segments: [[CGPoint]]
    var widths: [(at: CGFloat, width: CGFloat)]
}

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

// Drawn on a 1024 canvas with y pointing down, then moved and scaled to sit centred in the icon.
let strokes = [
    // The top of the head, from the nose back over the crown.
    Stroke(segments: [[p(440, 234), p(458, 226), p(478, 221), p(504, 220)], [p(504, 220), p(560, 218), p(596, 248), p(584, 300)]],
           widths: [(0, 18), (0.5, 42), (1, 32)]),
    // The lower jaw, open.
    Stroke(segments: [[p(584, 300), p(546, 304), p(506, 320), p(470, 346)]], widths: [(0, 34), (1, 16)]),
    // The ear.
    Stroke(segments: [[p(572, 236), p(588, 210), p(608, 190), p(636, 172)]], widths: [(0, 34), (1, 15)]),
    // The back, arched.
    Stroke(segments: [[p(584, 300), p(650, 390), p(660, 520), p(606, 650)], [p(606, 650), p(596, 674), p(586, 690), p(576, 706)]],
           widths: [(0, 32), (0.4, 46), (1, 32)]),
    // The front leg.
    Stroke(segments: [[p(626, 418), p(574, 430), p(532, 444), p(498, 462)], [p(498, 462), p(490, 490), p(480, 516), p(466, 540)]],
           widths: [(0, 38), (0.5, 28), (1, 16)]),
    // The hind leg.
    Stroke(segments: [[p(608, 624), p(560, 636), p(520, 650), p(488, 668)], [p(488, 668), p(482, 696), p(474, 720), p(462, 744)]],
           widths: [(0, 38), (0.5, 28), (1, 16)]),
    // The tail, curling up: what tells 犬 from 豕, the pig.
    Stroke(segments: [[p(576, 706), p(548, 772), p(572, 836), p(636, 840)], [p(636, 840), p(694, 842), p(716, 786), p(690, 748)],
                      [p(690, 748), p(670, 722), p(636, 726), p(628, 752)]],
           widths: [(0, 32), (0.3, 42), (0.75, 26), (1, 15)]),
]
let eye = (center: p(542, 266), radius: CGFloat(16))

let glyphScale: CGFloat = 1.16
let glyphOffset = CGPoint(x: -58, y: 6)

func place(_ point: CGPoint) -> CGPoint {
    CGPoint(x: (point.x + glyphOffset.x - 512) * glyphScale + 512, y: (point.y + glyphOffset.y - 512) * glyphScale + 512)
}

func bezier(_ c: [CGPoint], _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    let a = u * u * u, b = 3 * u * u * t, d = 3 * u * t * t, e = t * t * t
    return CGPoint(x: a * c[0].x + b * c[1].x + d * c[2].x + e * c[3].x,
                   y: a * c[0].y + b * c[1].y + d * c[2].y + e * c[3].y)
}

/// The width at a fraction of the stroke's length, eased between the stops.
func width(of stroke: Stroke, at t: CGFloat) -> CGFloat {
    for (from, to) in zip(stroke.widths, stroke.widths.dropFirst()) where t >= from.at && t <= to.at {
        var x = (t - from.at) / (to.at - from.at)
        x = x * x * (3 - 2 * x)
        return (from.width + (to.width - from.width) * x) * glyphScale
    }
    return stroke.widths.last!.width * glyphScale
}

/// The stroke's outline: one side out, a round cap, the other side back, a round cap.
func outline(_ stroke: Stroke) -> CGPath {
    let samplesPerSegment = 48
    var points: [CGPoint] = []
    for (index, segment) in stroke.segments.enumerated() {
        let last = index == stroke.segments.count - 1
        for k in 0..<(samplesPerSegment + (last ? 1 : 0)) {
            points.append(place(bezier(segment, CGFloat(k) / CGFloat(samplesPerSegment))))
        }
    }
    var lengths: [CGFloat] = [0]
    for (a, b) in zip(points, points.dropFirst()) { lengths.append(lengths.last! + hypot(b.x - a.x, b.y - a.y)) }
    let total = lengths.last!

    var left: [CGPoint] = [], right: [CGPoint] = [], normals: [CGFloat] = [], radii: [CGFloat] = []
    for (i, point) in points.enumerated() {
        let a = points[max(i - 1, 0)], b = points[min(i + 1, points.count - 1)]
        let dx = b.x - a.x, dy = b.y - a.y, length = max(hypot(dx, dy), 0.0001)
        let nx = -dy / length, ny = dx / length
        let r = width(of: stroke, at: lengths[i] / total) / 2
        left.append(CGPoint(x: point.x + nx * r, y: point.y + ny * r))
        right.append(CGPoint(x: point.x - nx * r, y: point.y - ny * r))
        normals.append(atan2(ny, nx))
        radii.append(r)
    }

    func cap(around center: CGPoint, radius: CGFloat, from angle: CGFloat) -> [CGPoint] {
        (1..<16).map { k in
            let a = angle - .pi * CGFloat(k) / 16
            return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
        }
    }

    let path = CGMutablePath()
    path.addLines(between: left
        + cap(around: points.last!, radius: radii.last!, from: normals.last!)
        + right.reversed()
        + cap(around: points[0], radius: radii[0], from: normals[0] + .pi))
    path.closeSubpath()
    return path
}

// MARK: - Rendering

struct Palette {
    var background: (top: RGB, middle: RGB, bottom: RGB)
    var glyph: RGB
    var eye: RGB
}

@discardableResult
func render(_ palette: Palette, to name: String) throws -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let s = CGFloat(size)
    // Draw with y pointing down, the way the glyph is defined.
    context.translateBy(x: 0, y: s)
    context.scaleBy(x: 1, y: -1)

    // A gradient falling at 160°: down and a little to the right.
    let angle = 160 * CGFloat.pi / 180
    let direction = CGPoint(x: sin(angle), y: -cos(angle))
    let reach = (abs(direction.x) + abs(direction.y)) * s / 2
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [color(palette.background.top), color(palette.background.middle), color(palette.background.bottom)] as CFArray,
                              locations: [0, 0.45, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: s / 2 - direction.x * reach, y: s / 2 - direction.y * reach),
                               end: CGPoint(x: s / 2 + direction.x * reach, y: s / 2 + direction.y * reach),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    context.setFillColor(color(palette.glyph))
    for stroke in strokes {
        context.addPath(outline(stroke))
        context.fillPath()
    }
    let center = place(eye.center), radius = eye.radius * glyphScale
    context.setFillColor(color(palette.eye))
    context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

    let image = context.makeImage()!
    try write(image, to: output.appendingPathComponent(name))
    return image
}

func write(_ image: CGImage, to url: URL) throws {
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try data.write(to: url)
}

/// The icon scaled down for sign-in, at each screen scale. SwiftUI rounds its corners.
func writeMark(_ icon: CGImage, named name: String) throws {
    for scale in [2, 3] {
        let side = markPoints * scale
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(icon, in: CGRect(x: 0, y: 0, width: side, height: side))
        try write(context.makeImage()!, to: markOutput.appendingPathComponent("\(name)@\(scale)x.png"))
    }
}

// Paper on Memos Blue, with a pale blue eye.
let light = try render(Palette(background: (hex(0x3D6B96), hex(0x305880), hex(0x1B3352)), glyph: hex(0xFAF9F5), eye: hex(0x9BC3E5)), to: "AppIcon.png")
// Dark: light ink on dark paper, the eye in Memos Blue's dark-mode tint.
let dark = try render(Palette(background: (hex(0x24211E), hex(0x1B1917), hex(0x141210)), glyph: hex(0xE9E7E3), eye: hex(0x5B97CF)), to: "AppIcon-Dark.png")
// Tinted: the system colours it by luminance, so a light glyph on black with the eye a step darker.
try render(Palette(background: (hex(0x000000), hex(0x000000), hex(0x000000)), glyph: hex(0xF2F2F2), eye: hex(0x8C8C8C)), to: "AppIcon-Tinted.png")
try writeMark(light, named: "AppMark")
try writeMark(dark, named: "AppMark-Dark")
print("Rendered app icons into \(output.path) and the sign-in mark into \(markOutput.path)")
