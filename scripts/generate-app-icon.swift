#!/usr/bin/env swift

import AppKit
import Foundation

let rootPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath
let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
let iconsetURL = rootURL.appendingPathComponent(".build/AppIcon.iconset", isDirectory: true)
let previewURL = rootURL.appendingPathComponent("dist/CodexQuotaViewer-icon-preview.png", isDirectory: false)
let blossomURL = findBlossomURL(rootURL: rootURL)

guard let blossomImage = NSImage(contentsOf: blossomURL) else {
    fputs("Failed to load Blossom SVG at \(blossomURL.path)\n", stderr)
    exit(1)
}

let fileManager = FileManager.default
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
try fileManager.createDirectory(at: previewURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let entries: [(base: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

for entry in entries {
    let pixelSize = entry.base * entry.scale
    let filename = entry.scale == 1
        ? "icon_\(entry.base)x\(entry.base).png"
        : "icon_\(entry.base)x\(entry.base)@2x.png"
    let outputURL = iconsetURL.appendingPathComponent(filename, isDirectory: false)
    try renderIcon(size: pixelSize, blossomImage: blossomImage).writePNG(to: outputURL)
}

try renderIcon(size: 1024, blossomImage: blossomImage).writePNG(to: previewURL)
print(iconsetURL.path)
print(previewURL.path)

private func findBlossomURL(rootURL: URL) -> URL {
    rootURL
        .appendingPathComponent("Sources", isDirectory: true)
        .appendingPathComponent("CodexQuotaViewer", isDirectory: true)
        .appendingPathComponent("Resources", isDirectory: true)
        .appendingPathComponent("openai-blossom-dark.svg", isDirectory: false)
}

private func renderIcon(size: Int, blossomImage: NSImage) -> NSImage {
    let sizeValue = CGFloat(size)
    let canvasSize = NSSize(width: sizeValue, height: sizeValue)
    let image = NSImage(size: canvasSize)
    image.lockFocus()

    let context = NSGraphicsContext.current?.cgContext
    context?.setShouldAntialias(true)
    context?.setAllowsAntialiasing(true)
    context?.interpolationQuality = .high

    drawBackground(in: NSRect(origin: .zero, size: canvasSize))
    drawHalo(size: sizeValue)
    let cardRect = drawFrontCard(size: sizeValue)
    drawBlossom(blossomImage, in: cardRect)
    drawMeters(in: cardRect)

    image.unlockFocus()
    return image
}

private func drawBackground(in rect: NSRect) {
    let radius = rect.width * 0.225
    let backgroundPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let shadow = NSShadow()
    shadow.shadowBlurRadius = rect.width * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.018)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
    shadow.set()

    NSGradient(
        colors: [
            color(hex: 0xFBFCFD),
            color(hex: 0xEEF2F6),
        ]
    )?.draw(in: backgroundPath, angle: -90)

    NSColor.black.withAlphaComponent(0.06).setStroke()
    backgroundPath.lineWidth = max(1, rect.width * 0.01)
    backgroundPath.stroke()

    let highlightRect = NSRect(
        x: rect.minX + rect.width * 0.05,
        y: rect.midY,
        width: rect.width * 0.9,
        height: rect.height * 0.38
    )
    let highlightPath = NSBezierPath(roundedRect: highlightRect, xRadius: radius * 0.75, yRadius: radius * 0.75)
    NSGraphicsContext.current?.saveGraphicsState()
    backgroundPath.addClip()
    NSGradient(
        colors: [
            NSColor.white.withAlphaComponent(0.7),
            NSColor.white.withAlphaComponent(0.0),
        ]
    )?.draw(in: highlightPath, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
}

private func drawHalo(size: CGFloat) {
    let rect = NSRect(
        x: size * 0.19,
        y: size * 0.18,
        width: size * 0.62,
        height: size * 0.62
    )
    let path = NSBezierPath(ovalIn: rect)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = size * 0.06
    shadow.shadowOffset = .zero
    shadow.shadowColor = color(hex: 0xB5C9E3, alpha: 0.35)
    shadow.set()
    NSGradient(
        colors: [
            color(hex: 0xD8E2F0, alpha: 0.85),
            color(hex: 0xEEF3FA, alpha: 0.15),
        ]
    )?.draw(in: path, relativeCenterPosition: .zero)
    NSGraphicsContext.current?.restoreGraphicsState()
}

@discardableResult
private func drawFrontCard(size: CGFloat) -> NSRect {
    let rect = NSRect(
        x: size * 0.24,
        y: size * 0.18,
        width: size * 0.52,
        height: size * 0.58
    )
    let radius = size * 0.12
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = size * 0.05
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.02)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
    shadow.set()

    NSGradient(
        colors: [
            color(hex: 0x151922),
            color(hex: 0x2A3341),
        ]
    )?.draw(in: path, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.08).setStroke()
    path.lineWidth = max(1, size * 0.008)
    path.stroke()

    let glossRect = NSRect(
        x: rect.minX + rect.width * 0.06,
        y: rect.maxY - rect.height * 0.20,
        width: rect.width * 0.88,
        height: rect.height * 0.16
    )
    let glossPath = NSBezierPath(
        roundedRect: glossRect,
        xRadius: glossRect.height / 2,
        yRadius: glossRect.height / 2
    )
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    NSGradient(
        colors: [
            NSColor.white.withAlphaComponent(0.12),
            NSColor.white.withAlphaComponent(0.0),
        ]
    )?.draw(in: glossPath, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    return rect
}

private func drawBlossom(_ blossomImage: NSImage, in cardRect: NSRect) {
    let rect = NSRect(
        x: cardRect.midX - cardRect.width * 0.185,
        y: cardRect.midY + cardRect.height * 0.03,
        width: cardRect.width * 0.37,
        height: cardRect.width * 0.37
    )
    let target = aspectFitRect(for: blossomImage.size, in: rect)
    blossomImage.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
}

private func drawMeters(in cardRect: NSRect) {
    let trackWidth = cardRect.width * 0.68
    let left = cardRect.midX - trackWidth / 2
    let primaryRect = NSRect(
        x: left,
        y: cardRect.minY + cardRect.height * 0.17,
        width: trackWidth,
        height: cardRect.height * 0.10
    )
    let secondaryRect = NSRect(
        x: left,
        y: cardRect.minY + cardRect.height * 0.08,
        width: trackWidth,
        height: cardRect.height * 0.065
    )

    drawMeterTrack(primaryRect, alpha: 0.18)
    drawMeterTrack(secondaryRect, alpha: 0.14)

    let primaryFill = NSRect(x: primaryRect.minX, y: primaryRect.minY, width: primaryRect.width * 0.82, height: primaryRect.height)
    let secondaryFill = NSRect(x: secondaryRect.minX, y: secondaryRect.minY, width: secondaryRect.width * 0.58, height: secondaryRect.height)

    NSGradient(
        colors: [
            color(hex: 0x4FC7FF),
            color(hex: 0x2E92FF),
        ]
    )?.draw(in: NSBezierPath(roundedRect: primaryFill, xRadius: primaryFill.height / 2, yRadius: primaryFill.height / 2), angle: 0)

    NSGradient(
        colors: [
            color(hex: 0x8AF0AA),
            color(hex: 0x57D07D),
        ]
    )?.draw(in: NSBezierPath(roundedRect: secondaryFill, xRadius: secondaryFill.height / 2, yRadius: secondaryFill.height / 2), angle: 0)
}

private func drawMeterTrack(_ rect: NSRect, alpha: CGFloat) {
    NSColor.white.withAlphaComponent(alpha).setFill()
    NSBezierPath(
        roundedRect: rect,
        xRadius: rect.height / 2,
        yRadius: rect.height / 2
    ).fill()
}

private func aspectFitRect(for sourceSize: NSSize, in containerRect: NSRect) -> NSRect {
    guard sourceSize.width > 0, sourceSize.height > 0 else {
        return containerRect
    }

    let scale = min(containerRect.width / sourceSize.width, containerRect.height / sourceSize.height)
    let fittedSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)

    return NSRect(
        x: containerRect.midX - fittedSize.width / 2,
        y: containerRect.midY - fittedSize.height / 2,
        width: fittedSize.width,
        height: fittedSize.height
    )
}

private func color(hex: Int, alpha: CGFloat = 1) -> NSColor {
    let red = CGFloat((hex >> 16) & 0xFF) / 255
    let green = CGFloat((hex >> 8) & 0xFF) / 255
    let blue = CGFloat(hex & 0xFF) / 255
    return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

private extension NSImage {
    func writePNG(to url: URL) throws {
        guard let tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiffRepresentation),
              let png = representation.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "CodexQuotaViewer.Icon",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"]
            )
        }

        try png.write(to: url)
    }
}
