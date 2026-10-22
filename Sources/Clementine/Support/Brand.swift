import AppKit
import SwiftUI

enum Brand {
    static let appName = "Clementine"

    /// Accent orange, matching the original's AccentColor (1.0, 0.32, 0.0).
    static let accentNS = NSColor(srgbRed: 1.0, green: 0.322, blue: 0.0, alpha: 1)
    static let accent = Color(nsColor: accentNS)
    /// The slightly softer orange used for filled buttons and highlights.
    static let buttonOrange = Color(red: 0.93, green: 0.38, blue: 0.17)
    static let highlightTop = Color(red: 0.74, green: 0.36, blue: 0.14)
    static let highlightBottom = Color(red: 0.95, green: 0.40, blue: 0.16)

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// Template image for the status item: a citrus cross-section.
    static func menuBarImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 7.6
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            // Knock out spokes between the segments.
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            context.setBlendMode(.clear)
            let segments = 8
            for index in 0..<segments {
                let angle = CGFloat(index) / CGFloat(segments) * .pi * 2 + .pi / 2
                context.setLineWidth(1.25)
                context.setLineCap(.round)
                context.move(to: center)
                context.addLine(to: CGPoint(x: center.x + cos(angle) * (radius - 1.6), y: center.y + sin(angle) * (radius - 1.6)))
                context.strokePath()
            }
            context.fillEllipse(in: CGRect(x: center.x - 1.4, y: center.y - 1.4, width: 2.8, height: 2.8))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The app icon, drawn in code so no artwork ships with the source.
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawAppIcon(in: rect)
            return true
        }
    }

    static func drawAppIcon(in rect: NSRect) {
        let s = rect.width / 1024
        let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 18 * s
        shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
        shadow.set()
        NSColor.white.setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        tilePath.addClip()
        let background = NSGradient(colors: [
            NSColor(srgbRed: 1.0, green: 0.72, blue: 0.30, alpha: 1),
            NSColor(srgbRed: 1.0, green: 0.45, blue: 0.10, alpha: 1),
            NSColor(srgbRed: 0.93, green: 0.30, blue: 0.05, alpha: 1),
        ])
        background?.draw(in: tile, angle: -90)

        let center = NSPoint(x: tile.midX, y: tile.midY - 6 * s)
        let rind: CGFloat = 300 * s
        // Soft drop shadow under the slice.
        NSGraphicsContext.saveGraphicsState()
        let sliceShadow = NSShadow()
        sliceShadow.shadowColor = NSColor(srgbRed: 0.55, green: 0.15, blue: 0, alpha: 0.45)
        sliceShadow.shadowBlurRadius = 30 * s
        sliceShadow.shadowOffset = NSSize(width: 0, height: -14 * s)
        sliceShadow.set()
        NSColor(srgbRed: 1.0, green: 0.97, blue: 0.90, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - rind, y: center.y - rind, width: rind * 2, height: rind * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let pith = rind - 26 * s
        NSColor(srgbRed: 1.0, green: 0.62, blue: 0.20, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - pith, y: center.y - pith, width: pith * 2, height: pith * 2)).fill()

        let flesh = pith - 14 * s
        let segments = 9
        let gap: CGFloat = 0.075
        for index in 0..<segments {
            let start = CGFloat(index) / CGFloat(segments) * 360 + 90
            let end = start + 360 / CGFloat(segments)
            let path = NSBezierPath()
            let inner: CGFloat = 26 * s
            let startRad = (start * .pi / 180) + gap
            let endRad = (end * .pi / 180) - gap
            path.move(to: NSPoint(x: center.x + cos(startRad) * inner, y: center.y + sin(startRad) * inner))
            path.appendArc(withCenter: center, radius: flesh, startAngle: start + gap * 180 / .pi * 0.35, endAngle: end - gap * 180 / .pi * 0.35)
            path.line(to: NSPoint(x: center.x + cos(endRad) * inner, y: center.y + sin(endRad) * inner))
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = 18 * s
            let gradient = NSGradient(colors: [
                NSColor(srgbRed: 1.0, green: 0.78, blue: 0.36, alpha: 1),
                NSColor(srgbRed: 1.0, green: 0.52, blue: 0.12, alpha: 1),
            ])
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            gradient?.draw(fromCenter: center, radius: 0, toCenter: center, radius: flesh, options: [])
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor(srgbRed: 1.0, green: 0.96, blue: 0.88, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 20 * s, y: center.y - 20 * s, width: 40 * s, height: 40 * s)).fill()

        // Leaf, the clementine's signature.
        let leaf = NSBezierPath()
        let base = NSPoint(x: center.x + rind * 0.52, y: center.y + rind * 0.80)
        leaf.move(to: base)
        leaf.curve(to: NSPoint(x: base.x + 190 * s, y: base.y + 120 * s),
                   controlPoint1: NSPoint(x: base.x + 30 * s, y: base.y + 120 * s),
                   controlPoint2: NSPoint(x: base.x + 120 * s, y: base.y + 150 * s))
        leaf.curve(to: base,
                   controlPoint1: NSPoint(x: base.x + 170 * s, y: base.y + 30 * s),
                   controlPoint2: NSPoint(x: base.x + 80 * s, y: base.y - 10 * s))
        NSGradient(colors: [
            NSColor(srgbRed: 0.40, green: 0.78, blue: 0.30, alpha: 1),
            NSColor(srgbRed: 0.16, green: 0.55, blue: 0.20, alpha: 1),
        ])?.draw(in: leaf, angle: -60)
        NSColor(srgbRed: 0.12, green: 0.42, blue: 0.14, alpha: 0.6).setStroke()
        let vein = NSBezierPath()
        vein.move(to: base)
        vein.curve(to: NSPoint(x: base.x + 170 * s, y: base.y + 112 * s),
                   controlPoint1: NSPoint(x: base.x + 60 * s, y: base.y + 60 * s),
                   controlPoint2: NSPoint(x: base.x + 120 * s, y: base.y + 100 * s))
        vein.lineWidth = 5 * s
        vein.stroke()

        // Glass sheen across the top of the tile.
        let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])
        sheen?.draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Writes an .iconset folder for iconutil.
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sizes: [(String, CGFloat)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, pixels) in sizes {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(pixels),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            drawAppIcon(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
}

/// The app icon as a SwiftUI view.
struct AppIconView: View {
    var size: CGFloat
    var body: some View {
        Image(nsImage: Brand.appIcon(size: size))
            .resizable()
            .frame(width: size, height: size)
    }
}
