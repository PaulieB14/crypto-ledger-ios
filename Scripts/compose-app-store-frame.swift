#!/usr/bin/env swift
import AppKit
import Foundation

// Composite one simulator screenshot into a 1320×2868 App Store frame:
// #0B0B0D ground, one gold headline, one device bezel. See docs/app-store-listing.md.
//
//   swift Scripts/compose-app-store-frame.swift <shot.png> <headline> <out.png>

guard CommandLine.arguments.count == 4 else {
    fputs("usage: compose-app-store-frame.swift <shot.png> <headline> <out.png>\n", stderr)
    exit(2)
}

let shotURL = URL(fileURLWithPath: CommandLine.arguments[1])
let headline = CommandLine.arguments[2]
let outURL = URL(fileURLWithPath: CommandLine.arguments[3])

guard let shot = NSImage(contentsOf: shotURL) else {
    fputs("could not read \(shotURL.path)\n", stderr)
    exit(1)
}

let canvasW: CGFloat = 1320
let canvasH: CGFloat = 2868
let paper = NSColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0D / 255, alpha: 1)
let gold = NSColor(srgbRed: 0xF5 / 255, green: 0xB1 / 255, blue: 0x3C / 255, alpha: 1)
let bezel = NSColor(srgbRed: 0x16 / 255, green: 0x17 / 255, blue: 0x1A / 255, alpha: 1)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasW),
    pixelsHigh: Int(canvasH),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("could not allocate bitmap\n", stderr)
    exit(1)
}
rep.size = NSSize(width: canvasW, height: canvasH)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

paper.setFill()
NSRect(x: 0, y: 0, width: canvasW, height: canvasH).fill()

let margin: CGFloat = 80
var fontSize: CGFloat = 72
var font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
var attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: gold,
]
var textSize = (headline as NSString).size(withAttributes: attributes)
while textSize.width > canvasW - margin * 2, fontSize > 46 {
    fontSize -= 2
    font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    attributes[.font] = font
    textSize = (headline as NSString).size(withAttributes: attributes)
}
let textRect = NSRect(
    x: (canvasW - textSize.width) / 2,
    y: canvasH - 220 - textSize.height,
    width: textSize.width,
    height: textSize.height
)
(headline as NSString).draw(in: textRect, withAttributes: attributes)

let shotSize = shot.size
let aspect = shotSize.width / max(shotSize.height, 1)
let maxScreenH: CGFloat = 1960
let maxScreenW: CGFloat = 980
var screenH = maxScreenH
var screenW = screenH * aspect
if screenW > maxScreenW {
    screenW = maxScreenW
    screenH = screenW / aspect
}
let bezelPad: CGFloat = 28
let deviceW = screenW + bezelPad * 2
let deviceH = screenH + bezelPad * 2
let deviceX = (canvasW - deviceW) / 2
let deviceTop: CGFloat = 300 + textSize.height
let deviceY = canvasH - deviceTop - deviceH

let deviceRect = NSRect(x: deviceX, y: deviceY, width: deviceW, height: deviceH)
let devicePath = NSBezierPath(roundedRect: deviceRect, xRadius: 78, yRadius: 78)
bezel.setFill()
devicePath.fill()
gold.withAlphaComponent(0.9).setStroke()
devicePath.lineWidth = 3
devicePath.stroke()

let screenRect = NSRect(
    x: deviceX + bezelPad,
    y: deviceY + bezelPad,
    width: screenW,
    height: screenH
)
let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 58, yRadius: 58)
screenPath.addClip()

// Aspect-fill the screenshot into the screen, centered.
let scale = max(screenW / shotSize.width, screenH / shotSize.height)
let drawW = shotSize.width * scale
let drawH = shotSize.height * scale
let drawRect = NSRect(
    x: screenRect.midX - drawW / 2,
    y: screenRect.midY - drawH / 2,
    width: drawW,
    height: drawH
)
shot.draw(in: drawRect, from: NSRect(origin: .zero, size: shotSize), operation: .copy, fraction: 1)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("could not encode png\n", stderr)
    exit(1)
}
do {
    try png.write(to: outURL)
} catch {
    fputs("could not write \(outURL.path): \(error)\n", stderr)
    exit(1)
}
