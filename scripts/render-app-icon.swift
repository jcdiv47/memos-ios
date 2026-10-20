#!/usr/bin/env swift
// Renders the app icon's default, dark and tinted PNGs into the asset catalog:
//   swift scripts/render-app-icon.swift
// A paper base with the Memos mark (a note with a folded corner and three lines of writing).
// Replace with an Icon Composer `.icon` file for the full layered Liquid Glass treatment.

import AppKit
import CoreGraphics

let size = 1024
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Memos/Resources/Assets.xcassets/AppIcon.appiconset")

struct Palette {
    var background: (CGFloat, CGFloat, CGFloat)
    var note: (CGFloat, CGFloat, CGFloat)
    var fold: (CGFloat, CGFloat, CGFloat)
    var ink: (CGFloat, CGFloat, CGFloat)
}

func color(_ c: (CGFloat, CGFloat, CGFloat), _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha)
}

func render(_ palette: Palette, to name: String) throws {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let s = CGFloat(size)
    context.setFillColor(color(palette.background))
    context.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // The note, with a folded top-right corner.
    let note = CGRect(x: s * 0.24, y: s * 0.2, width: s * 0.52, height: s * 0.6)
    let fold = s * 0.14
    let radius = s * 0.07
    let path = CGMutablePath()
    path.move(to: CGPoint(x: note.minX + radius, y: note.minY))
    path.addLine(to: CGPoint(x: note.maxX - radius, y: note.minY))
    path.addArc(tangent1End: CGPoint(x: note.maxX, y: note.minY), tangent2End: CGPoint(x: note.maxX, y: note.minY + radius), radius: radius)
    path.addLine(to: CGPoint(x: note.maxX, y: note.maxY - fold))
    path.addLine(to: CGPoint(x: note.maxX - fold, y: note.maxY))
    path.addLine(to: CGPoint(x: note.minX + radius, y: note.maxY))
    path.addArc(tangent1End: CGPoint(x: note.minX, y: note.maxY), tangent2End: CGPoint(x: note.minX, y: note.maxY - radius), radius: radius)
    path.addLine(to: CGPoint(x: note.minX, y: note.minY + radius))
    path.addArc(tangent1End: CGPoint(x: note.minX, y: note.minY), tangent2End: CGPoint(x: note.minX + radius, y: note.minY), radius: radius)
    path.closeSubpath()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.06, color: CGColor(gray: 0, alpha: 0.18))
    context.addPath(path)
    context.setFillColor(color(palette.note))
    context.fillPath()
    context.restoreGState()

    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: note.maxX, y: note.maxY - fold))
    corner.addLine(to: CGPoint(x: note.maxX - fold, y: note.maxY - fold))
    corner.addLine(to: CGPoint(x: note.maxX - fold, y: note.maxY))
    corner.closeSubpath()
    context.addPath(corner)
    context.setFillColor(color(palette.fold))
    context.fillPath()

    // Three lines of writing, the last one short.
    context.setFillColor(color(palette.ink))
    for (index, width) in [0.32, 0.32, 0.2].enumerated() {
        let y = note.maxY - fold - s * 0.08 - CGFloat(index) * s * 0.105
        let line = CGRect(x: note.minX + s * 0.08, y: y - s * 0.022, width: s * CGFloat(width), height: s * 0.044)
        context.addPath(CGPath(roundedRect: line, cornerWidth: s * 0.022, cornerHeight: s * 0.022, transform: nil))
        context.fillPath()
    }

    let image = context.makeImage()!
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try data.write(to: output.appendingPathComponent(name))
}

let blue: (CGFloat, CGFloat, CGFloat) = (0.1884, 0.3451, 0.5017)
try render(Palette(background: (0.9807, 0.9768, 0.9611), note: (1, 1, 1), fold: (0.8554, 0.8514, 0.8314), ink: blue), to: "AppIcon.png")
try render(Palette(background: (0.1127, 0.1235, 0.1375), note: (0.1535, 0.1662, 0.1827), fold: (0.2159, 0.2308, 0.2501), ink: (0.4038, 0.6398, 0.8794)), to: "AppIcon-Dark.png")
try render(Palette(background: (0, 0, 0), note: (0.35, 0.35, 0.35), fold: (0.2, 0.2, 0.2), ink: (0.95, 0.95, 0.95)), to: "AppIcon-Tinted.png")
print("Rendered app icons into \(output.path)")
