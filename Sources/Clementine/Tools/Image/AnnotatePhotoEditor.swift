import AppKit
import SwiftUI

// MARK: - Model

@MainActor
final class PhotoAnnotateModel: ObservableObject {
    let url: URL
    @Published private(set) var preview: CGImage?
    @Published private(set) var imageSize: CGSize = .zero
    @Published private(set) var hasAlpha = false
    @Published private(set) var loadError: String?
    @Published var annotations: [PhotoAnnotation] = []
    @Published var selectedID: UUID?
    @Published var editingID: UUID?
    @Published private(set) var tool: PhotoAnnotationTool = .arrow
    @Published private(set) var color = ImageToolColor(hex: 0xFF3B30)
    @Published private(set) var strokeWidth: Double = 5
    @Published private(set) var font: PhotoAnnotationFont = .system
    @Published private(set) var textSize: Double = 40
    @Published private(set) var zoom: Double = 2
    @Published var notice: String?
    @Published private(set) var canUndo = false

    weak var canvas: PhotoAnnotateCanvasView?
    /// Annotations added once the image loads (used for design snapshots).
    var seed: ((CGSize) -> [PhotoAnnotation])?
    /// Called once the photo has loaded (used by scripted snapshots).
    var onLoad: ((PhotoAnnotateModel) -> Void)?
    private var undoStack = ImageToolUndoStack<[PhotoAnnotation]>()

    init(url: URL) {
        self.url = url
    }

    func load() async {
        guard preview == nil, loadError == nil else { return }
        do {
            let loaded = try await ImageToolIO.loadAsync(url, maxPixel: 2400)
            imageSize = ImageToolIO.uprightSize(of: url) ?? CGSize(width: loaded.image.width, height: loaded.image.height)
            hasAlpha = loaded.hasAlpha
            preview = loaded.image
            if let seed {
                annotations = seed(imageSize)
                selectedID = annotations.last(where: { $0.kind == .text })?.id
            }
            onLoad?(self)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Image pixels per on-screen point at a typical editor size; keeps sizes consistent across images.
    var unit: CGFloat { max(imageSize.width, imageSize.height) / 1000 }
    var lineWidthPixels: CGFloat { CGFloat(strokeWidth) * unit }

    var selected: PhotoAnnotation? { selectedID.flatMap(annotation) }
    var hasDrawing: Bool { annotations.contains { $0.isFreehand } }

    func annotation(_ id: UUID) -> PhotoAnnotation? { annotations.first { $0.id == id } }

    func update(_ id: UUID, _ change: (inout PhotoAnnotation) -> Void) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        change(&annotations[index])
    }

    func remove(_ id: UUID) {
        annotations.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    // MARK: Undo

    func pushUndo(coalescing key: String? = nil) {
        undoStack.push(annotations, coalescing: key)
        canUndo = undoStack.canUndo
    }

    /// Restores the state saved by the latest `pushUndo` (used when a gesture turns out to be a no-op).
    func discardLastUndo() {
        _ = undoStack.pop()
        canUndo = undoStack.canUndo
    }

    func undo() {
        canvas?.endTextEditing(commit: false)
        guard let previous = undoStack.pop() else { return }
        annotations = previous
        if let selectedID, annotation(selectedID) == nil { self.selectedID = nil }
        canUndo = undoStack.canUndo
    }

    // MARK: Tools and styles

    func selectTool(_ newTool: PhotoAnnotationTool) {
        notice = nil
        canvas?.endTextEditing(commit: true)
        if newTool != tool { selectedID = nil }
        tool = newTool
        // "Press Text to add another box."
        if newTool == .text { addTextBox(at: nil) }
    }

    func setColor(_ value: ImageToolColor) {
        color = value
        guard let id = selectedID else { return }
        pushUndo(coalescing: "color-\(id)")
        update(id) { $0.color = value }
    }

    func setStrokeWidth(_ value: Double) {
        strokeWidth = value
        guard let id = selectedID, let selected, [.arrow, .rectangle, .ellipse, .stroke, .highlight, .magnifier].contains(selected.kind) else { return }
        pushUndo(coalescing: "width-\(id)")
        let pixels = lineWidthPixels
        update(id) { $0.lineWidth = pixels }
    }

    func setFont(_ value: PhotoAnnotationFont) {
        font = value
        guard let id = selectedID, selected?.kind == .text else { return }
        pushUndo(coalescing: "font-\(id)")
        update(id) { $0.font = value }
    }

    func setTextSize(_ value: Double) {
        textSize = value
        guard let id = selectedID, selected?.kind == .text else { return }
        pushUndo(coalescing: "size-\(id)")
        let pixels = CGFloat(value) * unit
        update(id) { $0.fontSize = pixels }
    }

    func setZoom(_ value: Double) {
        zoom = value
        guard let id = selectedID, selected?.kind == .magnifier else { return }
        pushUndo(coalescing: "zoom-\(id)")
        update(id) { $0.zoom = CGFloat(value) }
    }

    /// Reflects a newly selected annotation's style in the toolbar.
    func adoptStyle(of annotation: PhotoAnnotation) {
        color = annotation.color
        switch annotation.kind {
        case .text:
            font = annotation.font
            textSize = Double(annotation.fontSize / max(unit, 0.0001)).rounded()
        case .magnifier:
            zoom = Double(annotation.zoom)
        case .arrow, .rectangle, .ellipse, .stroke, .highlight:
            strokeWidth = Double(annotation.lineWidth / max(unit, 0.0001)).rounded()
        default: break
        }
    }

    // MARK: Actions

    func deleteSelected() {
        guard let id = selectedID else { return }
        if editingID == id { canvas?.endTextEditing(commit: false) }
        pushUndo()
        remove(id)
    }

    /// Removes all drawn strokes (freehand and highlight).
    func clearDrawing() {
        guard hasDrawing else { return }
        pushUndo()
        annotations.removeAll { $0.isFreehand }
        if let selectedID, annotation(selectedID) == nil { self.selectedID = nil }
    }

    @discardableResult
    func addTextBox(at point: CGPoint?) -> UUID? {
        guard imageSize.width > 0 else { return nil }
        let width = min(420 * unit, imageSize.width * 0.8)
        let fontSize = CGFloat(textSize) * unit
        var origin = point ?? CGPoint(x: (imageSize.width - width) / 2, y: imageSize.height * 0.42)
        if point == nil {
            // Stagger boxes added with the Text button so they don't stack exactly.
            let count = annotations.filter { $0.kind == .text }.count
            origin.y += CGFloat(count % 5) * fontSize * 1.6
        }
        origin.x = min(max(0, origin.x), max(0, imageSize.width - width))
        origin.y = min(max(0, origin.y), max(0, imageSize.height - fontSize * 1.3))
        pushUndo()
        var box = PhotoAnnotation(kind: .text, color: color, start: origin, end: CGPoint(x: origin.x + width, y: origin.y))
        box.font = font
        box.fontSize = fontSize
        annotations.append(box)
        selectedID = box.id
        if point == nil { canvas?.beginTextEditing(box.id) }
        return box.id
    }

    func addCallout(at point: CGPoint) -> UUID {
        pushUndo()
        let number = (annotations.filter { $0.kind == .callout }.map(\.number).max() ?? 0) + 1
        let callout = PhotoAnnotation(kind: .callout, color: color, start: point, end: point, number: number, radius: 18 * unit)
        annotations.append(callout)
        selectedID = callout.id
        return callout.id
    }

    func addMagnifier(at point: CGPoint) -> UUID {
        pushUndo()
        let radius = min(110 * unit, min(imageSize.width, imageSize.height) * 0.3)
        let bubble = PhotoAnnotation(kind: .magnifier, color: color, lineWidth: max(3, CGFloat(strokeWidth) * 0.8) * unit,
                                     start: point, end: point, zoom: CGFloat(zoom), radius: radius)
        annotations.append(bubble)
        selectedID = bubble.id
        return bubble.id
    }

    /// ⌘V: pastes an image (or image file) from the clipboard, centered and selected.
    func pasteImage() {
        let pasteboard = NSPasteboard.general
        var image: CGImage?
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let file = urls.first(where: { FileFormat.detect($0)?.family == .image }) {
            image = try? ImageIOHelpers.load(file, maxPixel: 4096).image
        }
        if image == nil, let nsImage = NSImage(pasteboard: pasteboard) {
            image = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let image, imageSize.width > 0 else {
            notice = "The clipboard has no image to paste."
            return
        }
        notice = nil
        let maxWidth = imageSize.width * 0.4, maxHeight = imageSize.height * 0.4
        let scale = min(maxWidth / CGFloat(image.width), maxHeight / CGFloat(image.height), 1)
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let origin = CGPoint(x: (imageSize.width - size.width) / 2, y: (imageSize.height - size.height) / 2)
        pushUndo()
        var pasted = PhotoAnnotation(kind: .image, color: color, start: origin,
                                     end: CGPoint(x: origin.x + size.width, y: origin.y + size.height))
        pasted.image = image
        annotations.append(pasted)
        selectedID = pasted.id
    }
}

// MARK: - Canvas

/// Interactive annotation surface: draws the photo and annotations, handles dragging, grips,
/// in-place text editing, ⌫, ⌘Z and ⌘V.
final class PhotoAnnotateCanvasView: ImageCanvasNSView, NSTextViewDelegate {
    weak var model: PhotoAnnotateModel?
    private(set) var textView: ImageCanvasTextView?

    private enum Grip {
        case arrowStart, arrowEnd, corner(ImageRectHandle), textLeft, textRight, magnifierRadius
    }

    private enum Drag {
        case none
        case create(UUID, origin: CGPoint)
        case freehand(UUID)
        case move(UUID, last: CGPoint, downAt: CGPoint, moved: Bool)
        case grip(UUID, Grip)
    }

    private var drag: Drag = .none

    // MARK: Sync

    func modelDidChange() {
        guard let model else { return }
        displayImage = model.preview
        imageSize = model.imageSize
        showsCheckerboard = model.hasAlpha
        if let editing = model.editingID, model.annotation(editing) == nil { endTextEditing(commit: false) }
        layoutTextView()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutTextView()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let model else { return }
        let rect = drawBaseImage(model.preview, context: context)
        guard rect.width > 0, model.preview != nil else { return }
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: viewScale, y: viewScale)
        PhotoAnnotationRenderer.draw(model.annotations, in: context, baseImage: model.preview, imageSize: model.imageSize,
                                     hiddenTextID: model.editingID)
        context.restoreGState()
        if let selected = model.selected { drawSelection(selected, context: context) }
    }

    private func drawSelection(_ annotation: PhotoAnnotation, context: CGContext) {
        switch annotation.kind {
        case .arrow:
            drawGrip(at: toView(annotation.start), context: context)
            drawGrip(at: toView(annotation.end), context: context)
        case .rectangle, .ellipse, .image:
            drawSelectionOutline(toView(annotation.rect).insetBy(dx: -4, dy: -4), context: context, dashed: true)
            for corner in ImageRectHandle.corners { drawGrip(at: corner.point(in: toView(annotation.rect)), context: context) }
        case .text:
            let rect = toView(annotation.bounds).insetBy(dx: -5, dy: -4)
            drawSelectionOutline(rect, context: context, dashed: model?.editingID != annotation.id)
            for x in [rect.minX, rect.maxX] { drawSideGrip(at: CGPoint(x: x, y: rect.midY), context: context) }
        case .stroke, .highlight, .callout:
            drawSelectionOutline(toView(annotation.bounds).insetBy(dx: -4, dy: -4), context: context, dashed: true)
        case .magnifier:
            let circle = toView(annotation.bounds).insetBy(dx: -4, dy: -4)
            context.saveGState()
            context.setStrokeColor(NSColor(Brand.buttonOrange).cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [5, 3])
            context.strokeEllipse(in: circle)
            context.restoreGState()
            drawGrip(at: CGPoint(x: circle.maxX, y: circle.midY), context: context)
        }
    }

    private func drawSideGrip(at point: CGPoint, context: CGContext) {
        let rect = CGRect(x: point.x - 3.5, y: point.y - 9, width: 7, height: 18)
        let path = CGPath(roundedRect: rect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 2, color: CGColor(gray: 0, alpha: 0.35))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        context.setStrokeColor(NSColor(Brand.buttonOrange).cgColor)
        context.setLineWidth(1.5)
        context.addPath(path)
        context.strokePath()
    }

    // MARK: Hit testing

    private func grips(of annotation: PhotoAnnotation) -> [(Grip, CGPoint)] {
        switch annotation.kind {
        case .arrow:
            return [(.arrowStart, toView(annotation.start)), (.arrowEnd, toView(annotation.end))]
        case .rectangle, .ellipse, .image:
            let rect = toView(annotation.rect)
            return ImageRectHandle.corners.map { (.corner($0), $0.point(in: rect)) }
        case .text:
            let rect = toView(annotation.bounds).insetBy(dx: -5, dy: -4)
            return [(.textLeft, CGPoint(x: rect.minX, y: rect.midY)), (.textRight, CGPoint(x: rect.maxX, y: rect.midY))]
        case .magnifier:
            let circle = toView(annotation.bounds).insetBy(dx: -4, dy: -4)
            return [(.magnifierRadius, CGPoint(x: circle.maxX, y: circle.midY))]
        case .stroke, .highlight, .callout:
            return []
        }
    }

    private func grip(at viewPoint: CGPoint, of annotation: PhotoAnnotation) -> Grip? {
        grips(of: annotation)
            .map { ($0.0, ImageCanvasGeometry.distance($0.1, viewPoint)) }
            .filter { $0.1 <= 9 }
            .min { $0.1 < $1.1 }?.0
    }

    private func annotation(at point: CGPoint) -> PhotoAnnotation? {
        guard let model else { return nil }
        let tolerance = 5 / max(viewScale, 0.0001)
        return model.annotations.last { $0.hitTest(point, tolerance: tolerance) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let model, model.preview != nil else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = toImage(viewPoint)
        model.notice = nil

        if let selected = model.selected, let grip = grip(at: viewPoint, of: selected) {
            model.pushUndo()
            drag = .grip(selected.id, grip)
            return
        }
        if !model.tool.drawsOverAnnotations || NSEvent.modifierFlags.contains(.command), let hit = annotation(at: point) {
            if model.editingID != hit.id {
                endTextEditing(commit: true)
                window?.makeFirstResponder(self)
            }
            model.selectedID = hit.id
            model.adoptStyle(of: hit)
            if event.clickCount >= 2, hit.kind == .text {
                beginTextEditing(hit.id)
                drag = .none
                return
            }
            drag = .move(hit.id, last: point, downAt: viewPoint, moved: false)
            return
        }
        endTextEditing(commit: true)
        window?.makeFirstResponder(self)
        model.selectedID = nil
        guard imageRect.insetBy(dx: -2, dy: -2).contains(viewPoint) else { drag = .none; return }

        switch model.tool {
        case .arrow, .rectangle, .ellipse:
            model.pushUndo()
            let kind: PhotoAnnotationKind = model.tool == .arrow ? .arrow : (model.tool == .rectangle ? .rectangle : .ellipse)
            let shape = PhotoAnnotation(kind: kind, color: model.color, lineWidth: model.lineWidthPixels, start: point, end: point)
            model.annotations.append(shape)
            drag = .create(shape.id, origin: point)
        case .draw, .highlight:
            model.pushUndo()
            let stroke = PhotoAnnotation(kind: model.tool == .draw ? .stroke : .highlight, color: model.color,
                                         lineWidth: model.lineWidthPixels, points: [point])
            model.annotations.append(stroke)
            drag = .freehand(stroke.id)
        case .text:
            if let id = model.addTextBox(at: point) {
                drag = .move(id, last: point, downAt: viewPoint, moved: false)
            }
        case .callout:
            let id = model.addCallout(at: point)
            drag = .move(id, last: point, downAt: viewPoint, moved: true)
        case .magnifier:
            let id = model.addMagnifier(at: point)
            drag = .move(id, last: point, downAt: viewPoint, moved: true)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = toImage(viewPoint)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            return
        case .create(let id, let origin):
            model.update(id) { annotation in
                var end = point
                if shift {
                    let dx = point.x - origin.x, dy = point.y - origin.y
                    if annotation.kind == .arrow {
                        // Snap to 45° steps.
                        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
                        let length = hypot(dx, dy)
                        end = CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
                    } else {
                        let side = max(abs(dx), abs(dy))
                        end = CGPoint(x: origin.x + (dx < 0 ? -side : side), y: origin.y + (dy < 0 ? -side : side))
                    }
                }
                annotation.end = end
            }
        case .freehand(let id):
            model.update(id) { annotation in
                if let last = annotation.points.last, ImageCanvasGeometry.distance(last, point) * viewScale < 1.5 { return }
                annotation.points.append(point)
            }
        case .move(let id, let last, let downAt, let moved):
            if !moved {
                guard ImageCanvasGeometry.distance(downAt, viewPoint) > 2.5 else { return }
                model.pushUndo()
            }
            let delta = CGVector(dx: point.x - last.x, dy: point.y - last.y)
            model.update(id) { $0.translate(by: delta) }
            drag = .move(id, last: point, downAt: downAt, moved: true)
            NSCursor.closedHand.set()
        case .grip(let id, let grip):
            applyGrip(grip, to: id, point: point, shift: shift)
        }
    }

    private func applyGrip(_ grip: Grip, to id: UUID, point: CGPoint, shift: Bool) {
        guard let model else { return }
        let minSize = 6 / max(viewScale, 0.0001)
        model.update(id) { annotation in
            switch grip {
            case .arrowStart: annotation.start = point
            case .arrowEnd: annotation.end = point
            case .corner(let handle):
                let rect = annotation.rect
                let keepsAspect = annotation.kind == .image || shift
                let aspect: CGFloat? = keepsAspect && rect.height > 0 ? rect.width / rect.height : nil
                let resized = handle.resize(rect, to: point, aspect: aspect, minSize: minSize, bounds: nil)
                annotation.start = resized.origin
                annotation.end = CGPoint(x: resized.maxX, y: resized.maxY)
            case .textLeft:
                annotation.start.x = min(point.x, annotation.end.x - annotation.fontSize * 1.5)
            case .textRight:
                annotation.end.x = max(point.x, annotation.start.x + annotation.fontSize * 1.5)
            case .magnifierRadius:
                annotation.radius = max(minSize * 4, ImageCanvasGeometry.distance(point, annotation.start))
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        switch drag {
        case .create(let id, _):
            if let shape = model.annotation(id), ImageCanvasGeometry.distance(shape.start, shape.end) * viewScale < 4 {
                // A click without a drag: drop the empty shape and its undo step.
                model.annotations.removeAll { $0.id == id }
                model.discardLastUndo()
            } else {
                model.selectedID = id
            }
        case .move(let id, _, _, let moved):
            if !moved, let annotation = model.annotation(id), annotation.kind == .text {
                beginTextEditing(id)
            }
        default:
            break
        }
        drag = .none
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: Cursor

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at viewPoint: CGPoint) {
        guard let model, model.preview != nil, imageRect.insetBy(dx: -12, dy: -12).contains(viewPoint) else {
            NSCursor.arrow.set()
            return
        }
        if let selected = model.selected, let grip = grip(at: viewPoint, of: selected) {
            switch grip {
            case .textLeft, .textRight: NSCursor.resizeLeftRight.set()
            default: NSCursor.crosshair.set()
            }
            return
        }
        if !model.tool.drawsOverAnnotations, annotation(at: toImage(viewPoint)) != nil {
            NSCursor.openHand.set()
            return
        }
        (model.tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            model.deleteSelected()
        case 36, 76: // return: edit the selected text box
            if let selected = model.selected, selected.kind == .text { beginTextEditing(selected.id) } else { super.keyDown(with: event) }
        default:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command), let characters = event.charactersIgnoringModifiers?.lowercased(),
               handleCommandKey(characters, shift: flags.contains(.shift)) {
                return
            }
            super.keyDown(with: event)
        }
    }

    override func handleCommandKey(_ characters: String, shift: Bool) -> Bool {
        guard let model else { return false }
        switch characters {
        case "z" where !shift:
            model.undo()
            return true
        case "v":
            model.pasteImage()
            return true
        default:
            return false
        }
    }

    // MARK: Text editing

    func beginTextEditing(_ id: UUID) {
        guard let model, let annotation = model.annotation(id), annotation.kind == .text else { return }
        if model.editingID == id, textView != nil { window?.makeFirstResponder(textView); return }
        endTextEditing(commit: true)
        model.selectedID = id
        model.editingID = id
        model.adoptStyle(of: annotation)
        let editor = ImageCanvasTextView(frame: toView(annotation.bounds))
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.string = annotation.text
        editor.delegate = self
        editor.setAccessibilityLabel("Annotation text")
        addSubview(editor)
        textView = editor
        layoutTextView()
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        needsDisplay = true
    }

    /// Ends in-place editing. Empty boxes are removed.
    func endTextEditing(commit: Bool) {
        guard let editor = textView else { return }
        textView = nil
        editor.delegate = nil
        let wasFirstResponder = window?.firstResponder === editor
        editor.removeFromSuperview()
        if let model, let id = model.editingID {
            model.editingID = nil
            if let annotation = model.annotation(id), annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.remove(id)
            }
        }
        if wasFirstResponder { window?.makeFirstResponder(self) }
        needsDisplay = true
    }

    private func layoutTextView() {
        guard let editor = textView, let model, let id = model.editingID, let annotation = model.annotation(id) else { return }
        let rect = toView(annotation.bounds)
        let font = annotation.font.font(size: annotation.fontSize * viewScale)
        if editor.font != font { editor.font = font }
        if editor.textColor != annotation.color.nsColor { editor.textColor = annotation.color.nsColor }
        editor.insertionPointColor = annotation.color.luminance > 0.85 ? NSColor(Brand.buttonOrange) : annotation.color.nsColor
        editor.typingAttributes = [.font: font, .foregroundColor: annotation.color.nsColor]
        let frame = CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, 10), height: max(rect.height, font.pointSize * 1.3) + 2)
        if editor.frame != frame {
            editor.frame = frame
            editor.textContainer?.containerSize = NSSize(width: frame.width, height: .greatestFiniteMagnitude)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = textView, let model, let id = model.editingID else { return }
        model.pushUndo(coalescing: "text-\(id)")
        let text = editor.string
        model.update(id) { $0.text = text }
        layoutTextView()
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing(commit: true)
            return true
        }
        return false
    }
}

struct PhotoAnnotateCanvas: NSViewRepresentable {
    @ObservedObject var model: PhotoAnnotateModel

    func makeNSView(context: Context) -> PhotoAnnotateCanvasView {
        let view = PhotoAnnotateCanvasView()
        view.model = model
        model.canvas = view
        view.modelDidChange()
        return view
    }

    func updateNSView(_ view: PhotoAnnotateCanvasView, context: Context) {
        view.model = model
        model.canvas = view
        view.modelDidChange()
    }
}

// MARK: - Editor

struct AnnotatePhotoEditor: View {
    @ObservedObject var session: ToolSession
    @StateObject private var model: PhotoAnnotateModel

    init(session: ToolSession, seed: ((CGSize) -> [PhotoAnnotation])? = nil, onLoad: ((PhotoAnnotateModel) -> Void)? = nil) {
        self.session = session
        let model = PhotoAnnotateModel(url: session.primaryURL)
        model.seed = seed
        model.onLoad = onLoad
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ToolScaffold(session: session) {
            VStack(spacing: 0) {
                toolbar
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                optionsBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                Divider().opacity(0.4)
                canvas
                Divider().opacity(0.4)
                hintBar
            }
        } footer: {
            ToolFooter(session: session, primaryTitle: "Save Annotated Copy", primaryEnabled: model.preview != nil, action: save) {
                HStack(spacing: 8) {
                    ImageToolTextButton(title: "Undo", symbol: "arrow.uturn.backward", help: "Undo last annotation (⌘Z)") { model.undo() }
                        .disabled(!model.canUndo)
                        .opacity(model.canUndo ? 1 : 0.45)
                    ImageToolTextButton(title: "Clear Drawing", symbol: "eraser", help: "Remove all drawn strokes") { model.clearDrawing() }
                        .disabled(!model.hasDrawing)
                        .opacity(model.hasDrawing ? 1 : 0.45)
                    ImageToolTextButton(title: "Delete", symbol: "trash", help: "Delete the selected annotation (⌫)") { model.deleteSelected() }
                        .disabled(model.selectedID == nil)
                        .opacity(model.selectedID == nil ? 0.45 : 1)
                }
            }
        }
        .task { await model.load() }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(PhotoAnnotationTool.allCases) { tool in
                ImageToolIconButton(symbol: tool.symbol, help: tool.title, isSelected: model.tool == tool) {
                    model.selectTool(tool)
                }
            }
            Divider().frame(height: 22).padding(.horizontal, 6)
            ImageToolIconButton(symbol: "doc.on.clipboard", help: "⌘V to paste an image. Drag to move or resize it.") {
                model.pasteImage()
            }
            Spacer(minLength: 12)
            ImageColorPalette(selection: Binding(get: { model.color }, set: { model.setColor($0) }), swatchSize: 16)
        }
    }

    /// Tool name and its options (width, font, zoom).
    private var optionsBar: some View {
        HStack(spacing: 12) {
            Text(model.tool.title)
                .font(.system(size: 12, weight: .semibold))
            toolOptions
            Spacer(minLength: 8)
        }
        .frame(height: 24)
    }

    /// The current tool's instructions, or a notice, under the canvas.
    private var hintBar: some View {
        HStack(spacing: 6) {
            Image(systemName: model.notice == nil ? "info.circle" : "exclamationmark.circle")
                .font(.system(size: 11.5))
                .foregroundStyle(model.notice == nil ? Color.secondary : Brand.buttonOrange)
            Text(model.notice ?? model.tool.hint)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var toolOptions: some View {
        switch model.tool {
        case .text:
            ToolSegmented(selection: Binding(get: { model.font }, set: { model.setFont($0) }),
                          options: PhotoAnnotationFont.allCases.map { ($0, $0.title) })
                .controlSize(.small)
                .help("Font")
            compactSlider(title: "Size", value: Binding(get: { model.textSize }, set: { model.setTextSize($0) }), range: 12...140)
        case .magnifier:
            Text("Zoom").font(.system(size: 11.5)).foregroundStyle(.secondary)
            ToolSegmented(selection: Binding(get: { model.zoom }, set: { model.setZoom($0) }),
                          options: [(1.5, "1.5×"), (2.0, "2×"), (3.0, "3×"), (4.0, "4×")])
                .controlSize(.small)
                .help("Magnifier zoom level")
        case .callout:
            Text("Numbers count up from 1; color follows the palette.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        default:
            compactSlider(title: "Width", value: Binding(get: { model.strokeWidth }, set: { model.setStrokeWidth($0) }), range: 1...24)
        }
    }

    private func compactSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Slider(value: value, in: range)
                .controlSize(.small)
                .frame(width: 110)
                .accessibilityLabel(title)
            Text("\(Int(value.wrappedValue.rounded()))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var canvas: some View {
        if let error = model.loadError {
            ToolMessageView(symbol: "exclamationmark.triangle", message: error)
        } else if model.preview == nil {
            ToolMessageView(symbol: "photo", message: "Loading photo…", isLoading: true)
        } else {
            PhotoAnnotateCanvas(model: model)
                .background(Color.primary.opacity(0.035))
        }
    }

    private func save() {
        model.canvas?.endTextEditing(commit: true)
        let annotations = model.annotations
        let size = model.imageSize
        session.runPerItem { url, context in
            try await PhotoAnnotationProcessor.process(url, annotations: annotations, imageSize: size, context: context)
        }
    }
}
