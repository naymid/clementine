import AppKit
import SwiftUI

/// Named `--snapshot` views that show the image editors in a working state. The `-interact`
/// variants drive the canvases with real mouse and key events after the photo loads, so the
/// rendered PNG shows the result of dragging, resizing, typing, deleting and undoing.
@MainActor
enum ImageToolSnapshots {
    static func register() {
        SnapshotRegistry.builders["image-adjust-demo"] = { files, _ in
            let session = ToolSession(tool: .editImage, urls: files)
            let initial = PhotoAdjustments(options: ["temperature": "45", "saturation": "30", "vibrance": "25", "vignette": "50", "contrast": "15"])
            let view = AdjustPhotoEditor(session: session, initial: initial, group: .color)
            return entry(view, session: session, size: CGSize(width: 940, height: 640))
        }
        SnapshotRegistry.builders["image-annotate-demo"] = { files, _ in
            let session = ToolSession(tool: .annotateImage, urls: files)
            let view = AnnotatePhotoEditor(session: session) { size in
                PhotoAnnotationProcessor.sampleAnnotations(for: size)
            }
            return entry(view, session: session, size: CGSize(width: 1000, height: 720))
        }
        SnapshotRegistry.builders["image-annotate-interact"] = { files, _ in
            let session = ToolSession(tool: .annotateImage, urls: files)
            let view = AnnotatePhotoEditor(session: session, onLoad: { model in
                after(0.5) { annotateScript(model) }
            })
            return entry(view, session: session, size: CGSize(width: 1000, height: 720))
        }
        SnapshotRegistry.builders["image-crop-demo"] = { files, _ in
            let session = ToolSession(tool: .cropImage, urls: files)
            return entry(CropImageEditor(session: session, aspect: .r4x3), session: session, size: CGSize(width: 960, height: 680))
        }
        SnapshotRegistry.builders["image-crop-interact"] = { files, _ in
            let session = ToolSession(tool: .cropImage, urls: files)
            let view = CropImageEditor(session: session, onLoad: { model in
                after(0.5) { cropScript(model) }
            })
            return entry(view, session: session, size: CGSize(width: 960, height: 680))
        }
        SnapshotRegistry.builders["image-redact-demo"] = { files, arguments in
            let session = ToolSession(tool: .redactImage, urls: files)
            let style: PhotoRedactStyle = arguments.contains("--solid") ? .solid : .blur
            let view = RedactPhotoEditor(session: session, style: style) { size in
                [CGRect(x: size.width * 0.06, y: size.height * 0.3, width: size.width * 0.45, height: size.height * 0.16),
                 CGRect(x: size.width * 0.06, y: size.height * 0.62, width: size.width * 0.5, height: size.height * 0.16)]
            }
            return entry(view, session: session, size: CGSize(width: 980, height: 600))
        }
        SnapshotRegistry.builders["image-redact-interact"] = { files, _ in
            let session = ToolSession(tool: .redactImage, urls: files)
            let view = RedactPhotoEditor(session: session, onLoad: { model in
                after(0.5) { redactScript(model) }
            })
            return entry(view, session: session, size: CGSize(width: 980, height: 600))
        }
        SnapshotRegistry.builders["image-collage-featured"] = { files, _ in
            let session = ToolSession(tool: .createCollage, urls: files)
            return entry(CreateCollageEditor(session: session, style: .featured), session: session, size: CGSize(width: 1000, height: 700))
        }
    }

    private static func entry<V: View>(_ view: V, session: ToolSession, size: CGSize) -> SnapshotRegistry.Entry {
        SnapshotRegistry.Entry(view: AnyView(view.environmentObject(session)), size: size)
    }

    private static func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
    }

    // MARK: Event helpers

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, in canvas: ImageCanvasNSView,
                              clickCount: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        let windowPoint = canvas.convert(canvas.toView(point), to: nil)
        return NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: flags,
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: canvas.window?.windowNumber ?? 0,
                                  context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)
    }

    /// Presses at `from`, drags in steps to `to` and releases, in image coordinates.
    private static func drag(_ canvas: ImageCanvasNSView, from: CGPoint, to: CGPoint, steps: Int = 10, flags: NSEvent.ModifierFlags = []) {
        if let down = mouse(.leftMouseDown, at: from, in: canvas, flags: flags) { canvas.mouseDown(with: down) }
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            if let moved = mouse(.leftMouseDragged, at: point, in: canvas, flags: flags) { canvas.mouseDragged(with: moved) }
        }
        if let up = mouse(.leftMouseUp, at: to, in: canvas, flags: flags) { canvas.mouseUp(with: up) }
    }

    private static func click(_ canvas: ImageCanvasNSView, at point: CGPoint) {
        if let down = mouse(.leftMouseDown, at: point, in: canvas) { canvas.mouseDown(with: down) }
        if let up = mouse(.leftMouseUp, at: point, in: canvas) { canvas.mouseUp(with: up) }
    }

    private static func key(_ canvas: NSView, code: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: canvas.window?.windowNumber ?? 0,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: code) else { return }
        canvas.keyDown(with: event)
    }

    // MARK: Scripts

    /// Arrow, rectangle (then moved by its border and resized by a corner), two callouts,
    /// a freehand stroke removed with ⌘Z, a deleted ellipse, a magnifier, and a text box typed in place.
    private static func annotateScript(_ model: PhotoAnnotateModel) {
        guard let canvas = model.canvas else { return }
        let w = model.imageSize.width, h = model.imageSize.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * y) }

        model.selectTool(.arrow)
        drag(canvas, from: p(0.08, 0.15), to: p(0.3, 0.4))

        model.selectTool(.rectangle)
        model.setColor(ImageToolColor(hex: 0x0A84FF))
        drag(canvas, from: p(0.40, 0.10), to: p(0.60, 0.30))
        drag(canvas, from: p(0.40, 0.20), to: p(0.45, 0.25))          // grab the left border: move right/down
        drag(canvas, from: p(0.65, 0.35), to: p(0.72, 0.42))          // bottom-right grip: resize

        model.selectTool(.callout)
        model.setColor(ImageToolColor(hex: 0xFF3B30))
        click(canvas, at: p(0.12, 0.62))
        click(canvas, at: p(0.20, 0.62))

        model.selectTool(.draw)
        drag(canvas, from: p(0.1, 0.85), to: p(0.4, 0.8))
        _ = canvas.handleCommandKey("z", shift: false)                 // ⌘Z removes the stroke

        model.selectTool(.ellipse)
        drag(canvas, from: p(0.75, 0.1), to: p(0.95, 0.3))
        key(canvas, code: 51, characters: "\u{8}")                     // ⌫ deletes the selected ellipse

        model.setZoom(3)
        model.selectTool(.magnifier)
        click(canvas, at: p(0.80, 0.70))

        model.selectedID = nil
        model.setColor(ImageToolColor.white)
        model.selectTool(.text)                                         // adds a box and starts editing
        if let editor = canvas.textView {
            editor.insertText("Typed in place", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    /// Drags the bottom-right grip inward, then drags the crop to the right and down.
    private static func cropScript(_ model: ImageCropModel) {
        guard let canvas = model.canvas else { return }
        let w = model.imageSize.width, h = model.imageSize.height
        drag(canvas, from: CGPoint(x: w, y: h), to: CGPoint(x: w * 0.6, y: h * 0.7))
        drag(canvas, from: CGPoint(x: w * 0.3, y: h * 0.3), to: CGPoint(x: w * 0.45, y: h * 0.4))
        model.objectWillChange.send()
    }

    /// Draws three rectangles, deletes one with ⌫, undoes the delete with ⌘Z, moves and resizes one, and switches to Blur.
    private static func redactScript(_ model: PhotoRedactModel) {
        guard let canvas = model.canvas else { return }
        let w = model.imageSize.width, h = model.imageSize.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * y) }
        drag(canvas, from: p(0.05, 0.25), to: p(0.35, 0.40))
        drag(canvas, from: p(0.05, 0.62), to: p(0.55, 0.78))
        drag(canvas, from: p(0.70, 0.10), to: p(0.90, 0.30))
        key(canvas, code: 51, characters: "\u{8}")                     // ⌫ deletes the third
        _ = canvas.handleCommandKey("z", shift: false)                 // ⌘Z brings it back
        drag(canvas, from: p(0.80, 0.20), to: p(0.75, 0.55))          // move it down
        model.selectedID = model.regions.first?.id
        drag(canvas, from: p(0.35, 0.40), to: p(0.45, 0.45))          // resize the first by its corner
        model.style = .blur
    }
}
