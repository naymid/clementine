import AppKit

/// The eight grips around a rectangle.
enum ImageRectHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    static let corners: [ImageRectHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    var isCorner: Bool { Self.corners.contains(self) }
    private var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    private var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    private var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    private var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    var cursor: NSCursor {
        switch self {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }

    /// The rect after dragging this grip to `point`. With `aspect` (width / height) the shape is kept,
    /// and with `bounds` the result stays inside them (top-down coordinates).
    func resize(_ rect: CGRect, to point: CGPoint, aspect: CGFloat?, minSize: CGFloat, bounds: CGRect?) -> CGRect {
        let limits = bounds ?? CGRect(x: -1e7, y: -1e7, width: 2e7, height: 2e7)
        let p = CGPoint(x: min(max(point.x, limits.minX), limits.maxX), y: min(max(point.y, limits.minY), limits.maxY))
        guard let aspect, aspect > 0 else {
            var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
            if movesLeft { minX = min(p.x, maxX - minSize) }
            if movesRight { maxX = max(p.x, minX + minSize) }
            if movesTop { minY = min(p.y, maxY - minSize) }
            if movesBottom { maxY = max(p.y, minY + minSize) }
            minX = max(minX, limits.minX); maxX = min(maxX, limits.maxX)
            minY = max(minY, limits.minY); maxY = min(maxY, limits.maxY)
            return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
        }
        let minWidth = max(minSize, minSize * aspect)
        if isCorner {
            let anchor = CGPoint(x: movesLeft ? rect.maxX : rect.minX, y: movesTop ? rect.maxY : rect.minY)
            let availableWidth = movesLeft ? anchor.x - limits.minX : limits.maxX - anchor.x
            let availableHeight = movesTop ? anchor.y - limits.minY : limits.maxY - anchor.y
            var width = max(abs(p.x - anchor.x), abs(p.y - anchor.y) * aspect)
            width = min(width, availableWidth, availableHeight * aspect)
            width = max(width, min(minWidth, availableWidth, availableHeight * aspect))
            let height = width / aspect
            return CGRect(x: movesLeft ? anchor.x - width : anchor.x, y: movesTop ? anchor.y - height : anchor.y,
                          width: width, height: height)
        }
        if movesLeft || movesRight {
            let anchorX = movesLeft ? rect.maxX : rect.minX
            let available = movesLeft ? anchorX - limits.minX : limits.maxX - anchorX
            let maxHeight = 2 * min(rect.midY - limits.minY, limits.maxY - rect.midY)
            var width = abs(p.x - anchorX)
            width = min(width, available, maxHeight * aspect)
            width = max(width, min(minWidth, available, maxHeight * aspect))
            let height = width / aspect
            return CGRect(x: movesLeft ? anchorX - width : anchorX, y: rect.midY - height / 2, width: width, height: height)
        }
        let anchorY = movesTop ? rect.maxY : rect.minY
        let available = movesTop ? anchorY - limits.minY : limits.maxY - anchorY
        let maxWidth = 2 * min(rect.midX - limits.minX, limits.maxX - rect.midX)
        var height = abs(p.y - anchorY)
        height = min(height, available, maxWidth / aspect)
        height = max(height, min(minWidth / aspect, available, maxWidth / aspect))
        let width = height * aspect
        return CGRect(x: rect.midX - width / 2, y: movesTop ? anchorY - height : anchorY, width: width, height: height)
    }
}

enum ImageCanvasGeometry {
    /// Moves `rect` by the smallest amount that puts it inside `bounds` (shrinking only if it is larger).
    static func clamp(_ rect: CGRect, inside bounds: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(result.width, bounds.width)
        result.size.height = min(result.height, bounds.height)
        result.origin.x = min(max(result.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.minY, bounds.minY), bounds.maxY - result.height)
        return result
    }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Distance from `p` to the segment a–b.
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// Distance from `p` to the outline of `rect`.
    static func distance(from p: CGPoint, toBorderOf rect: CGRect) -> CGFloat {
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        var best = CGFloat.greatestFiniteMagnitude
        for index in 0..<4 {
            best = min(best, distance(from: p, toSegment: corners[index], corners[(index + 1) % 4]))
        }
        return best
    }

    /// Approximate distance from `p` to the outline of the ellipse inscribed in `rect`.
    static func distance(from p: CGPoint, toEllipseIn rect: CGRect) -> CGFloat {
        let rx = max(rect.width / 2, 0.5), ry = max(rect.height / 2, 0.5)
        let nx = (p.x - rect.midX) / rx, ny = (p.y - rect.midY) / ry
        let normalized = sqrt(nx * nx + ny * ny)
        return abs(normalized - 1) * min(rx, ry)
    }
}

/// An NSView that shows one image fitted inside it and maps between view and image coordinates.
/// Coordinates are top-down. Subclasses add overlays and mouse handling.
class ImageCanvasNSView: NSView {
    var displayImage: CGImage? { didSet { needsDisplay = true } }
    /// Size of the image coordinate space (usually the full-resolution pixel size).
    var imageSize: CGSize = .zero { didSet { needsDisplay = true } }
    var showsCheckerboard = false
    var canvasInset: CGFloat = 16
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if !(window.firstResponder is NSText) { window.makeFirstResponder(self) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    var imageRect: CGRect {
        ImageToolDrawing.fitRect(for: imageSize, in: bounds.insetBy(dx: canvasInset, dy: canvasInset))
    }

    /// View points per image unit.
    var viewScale: CGFloat {
        imageSize.width > 0 ? imageRect.width / imageSize.width : 1
    }

    func toImage(_ point: CGPoint) -> CGPoint {
        let rect = imageRect, scale = viewScale
        return CGPoint(x: (point.x - rect.minX) / scale, y: (point.y - rect.minY) / scale)
    }

    func toView(_ point: CGPoint) -> CGPoint {
        let rect = imageRect, scale = viewScale
        return CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale)
    }

    func toView(_ rect: CGRect) -> CGRect {
        let origin = toView(rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * viewScale, height: rect.height * viewScale)
    }

    func imagePoint(for event: NSEvent) -> CGPoint {
        toImage(convert(event.locationInWindow, from: nil))
    }

    var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Draws the checkerboard (when needed) and the image, returning the image rect.
    @discardableResult
    func drawBaseImage(_ image: CGImage?, context: CGContext) -> CGRect {
        let rect = imageRect
        guard rect.width > 0 else { return rect }
        if showsCheckerboard {
            ImageToolDrawing.drawCheckerboard(in: rect, context: context, cell: 8, dark: isDarkAppearance)
        }
        if let image {
            context.interpolationQuality = .high
            ImageToolDrawing.drawUpright(image, in: rect, context: context)
        }
        return rect
    }

    /// A round white grip with an orange ring, in view coordinates.
    func drawGrip(at point: CGPoint, context: CGContext, radius: CGFloat = 5.5) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 2, color: CGColor(gray: 0, alpha: 0.35))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: rect)
        context.restoreGState()
        context.setStrokeColor(NSColor(Brand.buttonOrange).cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
    }

    /// Orange selection outline in view coordinates.
    func drawSelectionOutline(_ rect: CGRect, context: CGContext, dashed: Bool = false) {
        context.saveGState()
        context.setStrokeColor(NSColor(Brand.buttonOrange).cgColor)
        context.setLineWidth(1.5)
        if dashed { context.setLineDash(phase: 0, lengths: [5, 3]) }
        context.stroke(rect.insetBy(dx: -0.75, dy: -0.75))
        context.restoreGState()
    }

    /// The grip of `rect` (in image units) under a view-space point, if any.
    func handle(at viewPoint: CGPoint, of rect: CGRect, handles: [ImageRectHandle] = ImageRectHandle.allCases) -> ImageRectHandle? {
        let viewRect = toView(rect)
        var best: (ImageRectHandle, CGFloat)?
        for handle in handles {
            let distance = ImageCanvasGeometry.distance(handle.point(in: viewRect), viewPoint)
            if distance <= 9, distance < (best?.1 ?? .greatestFiniteMagnitude) { best = (handle, distance) }
        }
        return best?.0
    }

    // MARK: Keyboard shortcuts without a main menu

    /// Override to handle ⌘-shortcuts. Return true when handled.
    func handleCommandKey(_ characters: String, shift: Bool) -> Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), !(window?.firstResponder is NSText), window?.isKeyWindow ?? true,
           let characters = event.charactersIgnoringModifiers?.lowercased(),
           handleCommandKey(characters, shift: flags.contains(.shift)) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// An NSTextView that supports the usual editing shortcuts even though the app has no Edit menu.
final class ImageCanvasTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "x": cut(nil)
        case "c": copy(nil)
        case "v": pasteAsPlainText(nil)
        case "a": selectAll(nil)
        case "z":
            if flags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
