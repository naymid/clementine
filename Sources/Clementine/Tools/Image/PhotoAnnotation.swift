import AppKit

// MARK: - Model

/// The tools in Annotate Photo's toolbar.
enum PhotoAnnotationTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, ellipse, draw, highlight, text, callout, magnifier

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .draw: return "Draw"
        case .highlight: return "Highlight"
        case .text: return "Text"
        case .callout: return "Numbered Callout"
        case .magnifier: return "Magnifier"
        }
    }

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .draw: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .callout: return "1.circle"
        case .magnifier: return "plus.magnifyingglass"
        }
    }

    var hint: String {
        switch self {
        case .arrow: return "Drag from the tail toward the arrowhead. Drag an annotation to move it."
        case .rectangle: return "Drag to draw a rectangle. Drag an annotation to move it."
        case .ellipse: return "Drag to draw an ellipse. Drag an annotation to move it."
        case .draw: return "Drag to draw. Use Clear Drawing to remove all drawn strokes."
        case .highlight: return "Drag over the image to highlight."
        case .text: return "Press Text to add another box. Drag its border to move it and its side handles to change width."
        case .callout: return "Click to add numbered callouts; drag to move them. Their size stays fixed."
        case .magnifier: return "Choose a zoom level, then click the detail to place a magnifier bubble."
        }
    }

    /// Freehand tools always draw, even over existing annotations.
    var drawsOverAnnotations: Bool { self == .draw || self == .highlight }
}

enum PhotoAnnotationKind: String {
    case arrow, rectangle, ellipse, stroke, highlight, text, callout, magnifier, image
}

enum PhotoAnnotationFont: String, CaseIterable, Identifiable {
    case system, rounded, serif, mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .mono: return "Mono"
        }
    }

    func font(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: max(1, size), weight: .semibold)
        let design: NSFontDescriptor.SystemDesign
        switch self {
        case .system: return base
        case .rounded: design = .rounded
        case .serif: design = .serif
        case .mono: design = .monospaced
        }
        guard let descriptor = base.fontDescriptor.withDesign(design),
              let font = NSFont(descriptor: descriptor, size: max(1, size)) else { return base }
        return font
    }
}

/// One annotation in image pixel coordinates (top-down).
struct PhotoAnnotation: Identifiable {
    var id = UUID()
    var kind: PhotoAnnotationKind
    var color: ImageToolColor
    var lineWidth: CGFloat = 4
    /// Arrow tail, shape corner, text box top-left, callout or magnifier center.
    var start: CGPoint = .zero
    /// Arrow head, opposite shape corner; for text, `end.x` is the right edge.
    var end: CGPoint = .zero
    var points: [CGPoint] = []
    var text = ""
    var font: PhotoAnnotationFont = .system
    var fontSize: CGFloat = 32
    var number = 1
    var zoom: CGFloat = 2
    /// Callout and magnifier radius.
    var radius: CGFloat = 20
    var image: CGImage?

    var rect: CGRect { ImageCanvasGeometry.rect(from: start, to: end) }

    var isFreehand: Bool { kind == .stroke || kind == .highlight }

    mutating func translate(by delta: CGVector) {
        start.x += delta.dx; start.y += delta.dy
        end.x += delta.dx; end.y += delta.dy
        if !points.isEmpty {
            points = points.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) }
        }
    }

    /// Bounds used for hit testing and selection outlines.
    var bounds: CGRect {
        switch kind {
        case .arrow, .rectangle, .ellipse, .image:
            return rect
        case .stroke, .highlight:
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in points {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            let pad = PhotoAnnotationRenderer.strokeWidth(of: self) / 2
            return CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
        case .text:
            return PhotoAnnotationRenderer.textRect(of: self)
        case .callout, .magnifier:
            return CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    /// Whether `point` touches the annotation, with `tolerance` in image units.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let reach = lineWidth / 2 + tolerance
        switch kind {
        case .arrow:
            return ImageCanvasGeometry.distance(from: point, toSegment: start, end) <= max(reach, lineWidth * 1.8)
        case .rectangle:
            return ImageCanvasGeometry.distance(from: point, toBorderOf: rect) <= reach
        case .ellipse:
            return ImageCanvasGeometry.distance(from: point, toEllipseIn: rect) <= reach
        case .stroke, .highlight:
            let width = PhotoAnnotationRenderer.strokeWidth(of: self) / 2 + tolerance
            guard points.count > 1 else { return points.first.map { ImageCanvasGeometry.distance($0, point) <= width } ?? false }
            for index in 1..<points.count where ImageCanvasGeometry.distance(from: point, toSegment: points[index - 1], points[index]) <= width {
                return true
            }
            return false
        case .text, .image:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .callout, .magnifier:
            return ImageCanvasGeometry.distance(point, start) <= radius + tolerance
        }
    }
}

// MARK: - Rendering

/// Draws annotations into a top-down CGContext in image coordinates. The editor canvas and the
/// full-resolution export use the same code, so the saved copy matches the preview.
enum PhotoAnnotationRenderer {
    /// - Parameters:
    ///   - baseImage: the photo, drawn over `imageSize` (used by magnifier bubbles).
    ///   - hiddenTextID: a text box being edited live, whose text is drawn by the text view instead.
    static func draw(_ annotations: [PhotoAnnotation], in context: CGContext, baseImage: CGImage?, imageSize: CGSize,
                     hiddenTextID: UUID? = nil) {
        for annotation in annotations {
            context.saveGState()
            switch annotation.kind {
            case .arrow: drawArrow(annotation, in: context)
            case .rectangle, .ellipse: drawShape(annotation, in: context)
            case .stroke, .highlight: drawStroke(annotation, in: context)
            case .text where annotation.id != hiddenTextID: drawText(annotation, in: context)
            case .text: break
            case .callout: drawCallout(annotation, in: context)
            case .magnifier: drawMagnifier(annotation, in: context, baseImage: baseImage, imageSize: imageSize)
            case .image: drawPastedImage(annotation, in: context)
            }
            context.restoreGState()
        }
    }

    /// Soft drop shadow; CG shadows ignore the CTM, so blur is converted to device pixels.
    private static func setShadow(_ context: CGContext, blur: CGFloat, alpha: CGFloat = 0.35) {
        let scale = ImageToolDrawing.deviceScale(of: context)
        context.setShadow(offset: .zero, blur: blur * scale, color: CGColor(gray: 0, alpha: alpha))
    }

    static func strokeWidth(of annotation: PhotoAnnotation) -> CGFloat {
        annotation.kind == .highlight ? annotation.lineWidth * 4.5 : annotation.lineWidth
    }

    static func drawArrow(_ a: PhotoAnnotation, in context: CGContext) {
        let dx = a.end.x - a.start.x, dy = a.end.y - a.start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let ux = dx / length, uy = dy / length
        let headLength = min(max(a.lineWidth * 3.6, 10), length * 0.65)
        let headHalfWidth = headLength * 0.58
        let base = CGPoint(x: a.end.x - ux * headLength * 0.82, y: a.end.y - uy * headLength * 0.82)
        let back = CGPoint(x: a.end.x - ux * headLength, y: a.end.y - uy * headLength)
        setShadow(context, blur: max(2, a.lineWidth * 0.9))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setStrokeColor(a.color.cgColor)
        context.setFillColor(a.color.cgColor)
        context.setLineWidth(a.lineWidth)
        context.setLineCap(.round)
        context.move(to: a.start)
        context.addLine(to: base)
        context.strokePath()
        context.setLineJoin(.round)
        context.setLineWidth(max(1, a.lineWidth * 0.35))
        context.move(to: a.end)
        context.addLine(to: CGPoint(x: back.x - uy * headHalfWidth, y: back.y + ux * headHalfWidth))
        context.addLine(to: base)
        context.addLine(to: CGPoint(x: back.x + uy * headHalfWidth, y: back.y - ux * headHalfWidth))
        context.closePath()
        context.drawPath(using: .fillStroke)
        context.endTransparencyLayer()
    }

    static func drawShape(_ a: PhotoAnnotation, in context: CGContext) {
        let rect = a.rect
        guard rect.width > 0.5 || rect.height > 0.5 else { return }
        setShadow(context, blur: max(2, a.lineWidth * 0.8))
        context.setStrokeColor(a.color.cgColor)
        context.setLineWidth(a.lineWidth)
        context.setLineJoin(.round)
        if a.kind == .ellipse {
            context.strokeEllipse(in: rect)
        } else {
            let radius = min(a.lineWidth * 0.8, rect.width / 2, rect.height / 2)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        }
    }

    /// A smooth path through the points (quadratic curves between midpoints).
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if points.count == 2 { path.addLine(to: points[1]) } else { path.addLine(to: first) }
            return path
        }
        for index in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2, y: (points[index].y + points[index + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    static func drawStroke(_ a: PhotoAnnotation, in context: CGContext) {
        guard !a.points.isEmpty else { return }
        context.addPath(smoothPath(a.points))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(strokeWidth(of: a))
        if a.kind == .highlight {
            context.setStrokeColor(a.color.withAlpha(0.42).cgColor)
            context.setLineCap(.butt)
        } else {
            setShadow(context, blur: max(1.5, a.lineWidth * 0.6), alpha: 0.3)
            context.setStrokeColor(a.color.cgColor)
        }
        context.strokePath()
    }

    // MARK: Text

    static func textAttributes(for a: PhotoAnnotation, fontSize: CGFloat? = nil) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: a.font.font(size: fontSize ?? a.fontSize),
            .foregroundColor: a.color.nsColor,
            .paragraphStyle: paragraph,
        ]
    }

    static func textWidth(of a: PhotoAnnotation) -> CGFloat { max(a.end.x - a.start.x, a.fontSize) }

    /// The text box: its width is set by the user; its height follows the text.
    static func textRect(of a: PhotoAnnotation) -> CGRect {
        let width = textWidth(of: a)
        let string = a.text.isEmpty ? " " : (a.text.hasSuffix("\n") ? a.text + " " : a.text)
        let measured = NSAttributedString(string: string, attributes: textAttributes(for: a))
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let font = a.font.font(size: a.fontSize)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return CGRect(x: a.start.x, y: a.start.y, width: width, height: max(ceil(measured.height), lineHeight))
    }

    static func drawText(_ a: PhotoAnnotation, in context: CGContext) {
        guard !a.text.isEmpty else { return }
        let rect = textRect(of: a)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: a.color.luminance > 0.5 ? 0.55 : 0.25)
        shadow.shadowBlurRadius = max(1.5, a.fontSize * 0.08) * ImageToolDrawing.deviceScale(of: context)
        shadow.shadowOffset = .zero
        var attributes = textAttributes(for: a)
        attributes[.shadow] = shadow
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSAttributedString(string: a.text, attributes: attributes)
            .draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Callouts, magnifiers, images

    static func drawCallout(_ a: PhotoAnnotation, in context: CGContext) {
        let circle = CGRect(x: a.start.x - a.radius, y: a.start.y - a.radius, width: a.radius * 2, height: a.radius * 2)
        context.saveGState()
        setShadow(context, blur: a.radius * 0.25)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: circle)
        context.restoreGState()
        context.setFillColor(a.color.cgColor)
        context.fillEllipse(in: circle.insetBy(dx: a.radius * 0.12, dy: a.radius * 0.12))
        let label = "\(a.number)"
        let fontSize = a.radius * (label.count > 1 ? 0.9 : 1.08)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let textColor: NSColor = a.color.luminance > 0.72 ? .black : .white
        let string = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: textColor])
        let size = string.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        string.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawMagnifier(_ a: PhotoAnnotation, in context: CGContext, baseImage: CGImage?, imageSize: CGSize) {
        let circle = CGRect(x: a.start.x - a.radius, y: a.start.y - a.radius, width: a.radius * 2, height: a.radius * 2)
        let ring = max(a.lineWidth, a.radius * 0.035)
        context.saveGState()
        setShadow(context, blur: a.radius * 0.18, alpha: 0.45)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: circle.insetBy(dx: -ring, dy: -ring))
        context.restoreGState()
        if let baseImage {
            context.saveGState()
            context.addEllipse(in: circle)
            context.clip()
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(circle)
            context.translateBy(x: a.start.x, y: a.start.y)
            context.scaleBy(x: a.zoom, y: a.zoom)
            context.translateBy(x: -a.start.x, y: -a.start.y)
            context.interpolationQuality = .high
            ImageToolDrawing.drawUpright(baseImage, in: CGRect(origin: .zero, size: imageSize), context: context)
            context.restoreGState()
        }
        context.setStrokeColor(a.color.cgColor)
        context.setLineWidth(ring)
        context.strokeEllipse(in: circle.insetBy(dx: -ring / 2, dy: -ring / 2))
    }

    static func drawPastedImage(_ a: PhotoAnnotation, in context: CGContext) {
        guard let image = a.image else { return }
        setShadow(context, blur: max(3, a.rect.width * 0.02), alpha: 0.3)
        ImageToolDrawing.drawUpright(image, in: a.rect, context: context)
    }
}

// MARK: - Export

enum PhotoAnnotationProcessor {
    /// Draws `annotations` (in `imageSize` coordinates) over the full-resolution photo and saves "-annotated".
    static func process(_ url: URL, annotations: [PhotoAnnotation], imageSize: CGSize, context: JobContext) async throws -> [URL] {
        let loaded = try ImageIOHelpers.load(url)
        context.progress(0.25)
        let image = loaded.image
        guard let canvas = ImageToolDrawing.makeCanvas(width: image.width, height: image.height, colorSpace: image.colorSpace) else {
            throw ImageError.writeFailed("Could not create the annotated image.")
        }
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ImageToolDrawing.drawUpright(image, in: full, context: canvas)
        let scale = imageSize.width > 0 ? CGFloat(image.width) / imageSize.width : 1
        canvas.saveGState()
        canvas.scaleBy(x: scale, y: scale)
        PhotoAnnotationRenderer.draw(annotations, in: canvas, baseImage: image,
                                     imageSize: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        canvas.restoreGState()
        guard let output = canvas.makeImage() else { throw ImageError.writeFailed("Could not create the annotated image.") }
        context.progress(0.7)
        return [try await ImageToolIO.save(output, beside: url, suffix: "-annotated", properties: loaded.properties, context: context)]
    }

    /// A representative set of annotations for headless tests, laid out relative to the image.
    static func sampleAnnotations(for size: CGSize, text: String = "Look here") -> [PhotoAnnotation] {
        let unit = max(size.width, size.height) / 1000
        let w = size.width, h = size.height
        let red = ImageToolColor(hex: 0xFF3B30), yellow = ImageToolColor(hex: 0xFFD60A), blue = ImageToolColor(hex: 0x0A84FF)
        var items: [PhotoAnnotation] = []
        items.append(PhotoAnnotation(kind: .highlight, color: yellow, lineWidth: 6 * unit,
                                     points: stride(from: 0.08, through: 0.42, by: 0.02).map { CGPoint(x: w * $0, y: h * 0.86) }))
        items.append(PhotoAnnotation(kind: .arrow, color: red, lineWidth: 6 * unit,
                                     start: CGPoint(x: w * 0.12, y: h * 0.18), end: CGPoint(x: w * 0.36, y: h * 0.42)))
        items.append(PhotoAnnotation(kind: .rectangle, color: red, lineWidth: 5 * unit,
                                     start: CGPoint(x: w * 0.44, y: h * 0.12), end: CGPoint(x: w * 0.66, y: h * 0.34)))
        items.append(PhotoAnnotation(kind: .ellipse, color: blue, lineWidth: 5 * unit,
                                     start: CGPoint(x: w * 0.70, y: h * 0.10), end: CGPoint(x: w * 0.92, y: h * 0.32)))
        items.append(PhotoAnnotation(kind: .stroke, color: blue, lineWidth: 5 * unit,
                                     points: stride(from: 0.0, through: 1.0, by: 0.05).map {
                                         CGPoint(x: w * (0.08 + 0.3 * $0), y: h * (0.66 + 0.06 * sin($0 * 12)))
                                     }))
        var label = PhotoAnnotation(kind: .text, color: ImageToolColor.white, start: CGPoint(x: w * 0.44, y: h * 0.44),
                                    end: CGPoint(x: w * 0.44 + 380 * unit, y: h * 0.44))
        label.text = text
        label.fontSize = 44 * unit
        label.font = .rounded
        items.append(label)
        for (index, x) in [0.50, 0.60].enumerated() {
            items.append(PhotoAnnotation(kind: .callout, color: red, start: CGPoint(x: w * x, y: h * 0.66), number: index + 1, radius: 18 * unit))
        }
        items.append(PhotoAnnotation(kind: .magnifier, color: ImageToolColor.white, lineWidth: 4 * unit,
                                     start: CGPoint(x: w * 0.82, y: h * 0.70), zoom: 2.5, radius: 110 * unit))
        return items
    }
}
