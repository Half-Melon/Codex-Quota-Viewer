import AppKit
import Foundation

enum MeterIconState {
    case normal
    case stale
    case degraded
}

struct StatusItemRenderer {
    private let brandCanvasSize = NSSize(width: 18, height: 18)
    private let brandContentRect = NSRect(x: 1, y: 1, width: 16, height: 16)

    func makeBrandImage(for appearance: NSAppearance) -> NSImage {
        if let sourceImage = loadOfficialBlossomSource(for: appearance) {
            return wrapBrandImage(sourceImage)
        }

        let image = NSImage(size: brandCanvasSize)
        image.lockFocus()

        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()

            // Text mode needs a larger, denser icon than the compact meter glyph.
            context.translateBy(x: 0.45, y: -2.2)
            context.scaleBy(x: 1.38, y: 1.38)

            NSColor.black.setFill()
            brandBlobPath().fill()

            context.setBlendMode(.clear)

            let chevron = NSBezierPath()
            chevron.lineWidth = 1.9
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.move(to: NSPoint(x: 4.0, y: 5.0))
            chevron.line(to: NSPoint(x: 6.15, y: 7.0))
            chevron.line(to: NSPoint(x: 4.0, y: 9.0))
            chevron.stroke()

            let bar = NSBezierPath(
                roundedRect: NSRect(x: 7.6, y: 6.1, width: 3.0, height: 1.8),
                xRadius: 0.9,
                yRadius: 0.9
            )
            bar.fill()

            context.restoreGState()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func loadOfficialBlossomSource(for appearance: NSAppearance) -> NSImage? {
        let resourceName = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? "openai-blossom-dark"
            : "openai-blossom-light"

        guard let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("AppIconAssets", isDirectory: true)
            .appendingPathComponent("\(resourceName).svg", isDirectory: false),
              let image = NSImage(contentsOf: resourceURL) else {
            return nil
        }

        return image
    }

    private func wrapBrandImage(_ sourceImage: NSImage) -> NSImage {
        let image = NSImage(size: brandCanvasSize)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: brandCanvasSize).fill()

        let targetRect = aspectFitRect(for: sourceImage.size, in: brandContentRect)
        sourceImage.draw(
            in: targetRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func aspectFitRect(for sourceSize: NSSize, in containerRect: NSRect) -> NSRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return containerRect
        }

        let scale = min(
            containerRect.width / sourceSize.width,
            containerRect.height / sourceSize.height
        )
        let fittedSize = NSSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )

        return NSRect(
            x: containerRect.midX - (fittedSize.width / 2),
            y: containerRect.midY - (fittedSize.height / 2),
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    func makeMeterImage(
        primaryRemaining: Double?,
        secondaryRemaining: Double?,
        state: MeterIconState
    ) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let alpha: CGFloat
        switch state {
        case .normal:
            alpha = 1
        case .stale:
            alpha = 0.55
        case .degraded:
            alpha = 0.35
        }

        let topTrackRect = NSRect(x: 2, y: 10, width: 14, height: 4)
        let bottomTrackRect = NSRect(x: 2, y: 4, width: 14, height: 2)

        drawTrack(in: topTrackRect, alpha: alpha)
        drawTrack(in: bottomTrackRect, alpha: alpha)
        drawFill(in: topTrackRect, ratio: primaryRemaining ?? 0, alpha: alpha)
        drawFill(in: bottomTrackRect, ratio: secondaryRemaining ?? 0, alpha: alpha)

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func drawTrack(in rect: NSRect, alpha: CGFloat) {
        NSColor.black.withAlphaComponent(0.18 * alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }

    private func drawFill(in rect: NSRect, ratio: Double, alpha: CGFloat) {
        let width = max(0, min(rect.width, rect.width * CGFloat(ratio)))
        guard width > 0 else { return }
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        NSColor.black.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 1, yRadius: 1).fill()
    }

    private func brandBlobPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 7.0, y: 12.0))
        path.curve(
            to: NSPoint(x: 10.35, y: 11.2),
            controlPoint1: NSPoint(x: 8.2, y: 12.55),
            controlPoint2: NSPoint(x: 9.55, y: 12.25)
        )
        path.curve(
            to: NSPoint(x: 11.95, y: 8.55),
            controlPoint1: NSPoint(x: 11.35, y: 10.55),
            controlPoint2: NSPoint(x: 12.2, y: 9.75)
        )
        path.curve(
            to: NSPoint(x: 10.85, y: 5.6),
            controlPoint1: NSPoint(x: 11.8, y: 7.3),
            controlPoint2: NSPoint(x: 11.55, y: 6.15)
        )
        path.curve(
            to: NSPoint(x: 7.95, y: 4.35),
            controlPoint1: NSPoint(x: 10.05, y: 5.0),
            controlPoint2: NSPoint(x: 8.9, y: 4.25)
        )
        path.curve(
            to: NSPoint(x: 4.7, y: 4.9),
            controlPoint1: NSPoint(x: 6.95, y: 4.35),
            controlPoint2: NSPoint(x: 5.5, y: 4.15)
        )
        path.curve(
            to: NSPoint(x: 2.1, y: 7.55),
            controlPoint1: NSPoint(x: 3.45, y: 5.45),
            controlPoint2: NSPoint(x: 2.2, y: 6.25)
        )
        path.curve(
            to: NSPoint(x: 3.3, y: 10.3),
            controlPoint1: NSPoint(x: 1.9, y: 8.85),
            controlPoint2: NSPoint(x: 2.1, y: 9.85)
        )
        path.curve(
            to: NSPoint(x: 7.0, y: 12.0),
            controlPoint1: NSPoint(x: 4.35, y: 11.35),
            controlPoint2: NSPoint(x: 5.8, y: 12.2)
        )
        path.close()
        return path
    }
}
