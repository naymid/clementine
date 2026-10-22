import AppKit
import CoreImage
import SwiftUI
import Vision

// MARK: - Model types

struct PhotoRedactRegion: Identifiable, Equatable {
    var id = UUID()
    /// Image pixels, top-down.
    var rect: CGRect
}

enum PhotoRedactStyle: String, CaseIterable, Identifiable {
    case solid, blur
    var id: String { rawValue }
    var title: String { self == .solid ? "Solid" : "Blur" }
}

// MARK: - Processing

enum PhotoRedactProcessor {
    /// Covers `regions` (pixels of `image`, top-down). Solid is opaque black; Blur pixelates coarsely
    /// and then blurs, so the hidden content can't be read back.
    static func apply(_ regions: [CGRect], style: PhotoRedactStyle, to image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = ImageToolDrawing.makeCanvas(width: width, height: height, colorSpace: image.colorSpace) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        ImageToolDrawing.drawUpright(image, in: bounds, context: context)
        let areas = regions.map { $0.integral.intersection(bounds) }.filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
        switch style {
        case .solid:
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for area in areas { context.fill(area) }
        case .blur:
            let source = CIImage(cgImage: image).clampedToExtent()
            let longest = CGFloat(max(width, height))
            for area in areas {
                let block = max(longest / 70, min(area.width, area.height) / 4, 6)
                // Core Image is bottom-up.
                let ciRect = CGRect(x: area.minX, y: CGFloat(height) - area.maxY, width: area.width, height: area.height)
                let patch = source
                    .applyingFilter("CIPixellate", parameters: [kCIInputCenterKey: CIVector(x: ciRect.minX, y: ciRect.minY),
                                                                kCIInputScaleKey: block])
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: block * 0.7])
                    .cropped(to: ciRect)
                if let rendered = ImageToolIO.render(patch, extent: ciRect) {
                    // Opaque underlay so transparent pixels can't reveal anything either.
                    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
                    context.fill(area)
                    ImageToolDrawing.drawUpright(rendered, in: area, context: context)
                } else {
                    context.setFillColor(CGColor(gray: 0, alpha: 1))
                    context.fill(area)
                }
            }
        }
        return context.makeImage()
    }

    /// Face rectangles in 0…1 units (top-down).
    static func detectFaces(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).map { flip($0.boundingBox) }
    }

    /// Lines of text in 0…1 units (top-down).
    static func detectText(in image: CGImage) throws -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).map { flip($0.boundingBox) }
    }

    private static func flip(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// Converts detected 0…1 boxes to padded pixel rects for an image of `size`.
    static func regions(from boxes: [CGRect], imageSize size: CGSize, padding: CGFloat) -> [CGRect] {
        boxes.map { box in
            let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
            let pad = max(2, min(rect.width, rect.height) * padding)
            return rect.insetBy(dx: -pad, dy: -pad).intersection(CGRect(origin: .zero, size: size))
        }
    }

    /// Saves "-redacted" with all metadata removed.
    static func process(_ url: URL, regions: [CGRect], imageSize: CGSize, style: PhotoRedactStyle, context: JobContext) async throws -> [URL] {
        let loaded = try ImageIOHelpers.load(url)
        context.progress(0.25)
        let scale = imageSize.width > 0 ? CGFloat(loaded.image.width) / imageSize.width : 1
        let scaled = regions.map { CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale) }
        guard let output = apply(scaled, style: style, to: loaded.image) else {
            throw ImageError.writeFailed("Could not redact \(url.lastPathComponent).")
        }
        context.progress(0.7)
        return [try await ImageToolIO.save(output, beside: url, suffix: "-redacted", stripMetadata: true, context: context)]
    }
}

// MARK: - Model

@MainActor
final class PhotoRedactModel: ObservableObject {
    let url: URL
    @Published private(set) var preview: CGImage?
    @Published private(set) var imageSize: CGSize = .zero
    @Published private(set) var hasAlpha = false
    @Published private(set) var loadError: String?
    @Published var regions: [PhotoRedactRegion] = []
    @Published var selectedID: UUID?
    @Published var style: PhotoRedactStyle = .solid
    @Published private(set) var detecting: String?
    @Published var notice: String?
    @Published private(set) var canUndo = false

    var seed: ((CGSize) -> [CGRect])?
    /// Called once the photo has loaded (used by scripted snapshots).
    var onLoad: ((PhotoRedactModel) -> Void)?
    weak var canvas: PhotoRedactCanvasView?
    private var undoStack = ImageToolUndoStack<[PhotoRedactRegion]>()

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
                regions = seed(imageSize).map { PhotoRedactRegion(rect: $0) }
                selectedID = regions.first?.id
            }
            onLoad?(self)
        } catch {
            loadError = error.localizedDescription
        }
    }

    var selected: PhotoRedactRegion? { regions.first { $0.id == selectedID } }

    func pushUndo() {
        undoStack.push(regions)
        canUndo = undoStack.canUndo
    }

    func discardLastUndo() {
        _ = undoStack.pop()
        canUndo = undoStack.canUndo
    }

    func undo() {
        guard let previous = undoStack.pop() else { return }
        regions = previous
        if let selectedID, !regions.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        canUndo = undoStack.canUndo
    }

    func update(_ id: UUID, rect: CGRect) {
        guard let index = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[index].rect = rect
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        pushUndo()
        regions.removeAll { $0.id == id }
        selectedID = nil
    }

    func removeAll() {
        guard !regions.isEmpty else { return }
        pushUndo()
        regions.removeAll()
        selectedID = nil
    }

    enum Detection { case faces, text }

    /// Adds rectangles for faces or text found by Vision, skipping ones already covered.
    func detect(_ kind: Detection) async {
        guard let preview, detecting == nil else { return }
        detecting = kind == .faces ? "Finding faces…" : "Finding text…"
        notice = nil
        let size = imageSize
        let result: Result<[CGRect], Error> = await Task.detached(priority: .userInitiated) {
            Result {
                let boxes = kind == .faces ? try PhotoRedactProcessor.detectFaces(in: preview) : try PhotoRedactProcessor.detectText(in: preview)
                return PhotoRedactProcessor.regions(from: boxes, imageSize: size, padding: kind == .faces ? 0.18 : 0.12)
            }
        }.value
        detecting = nil
        switch result {
        case .failure(let error):
            notice = "Detection failed: \(error.localizedDescription)"
        case .success(let found):
            let fresh = found.filter { candidate in
                !regions.contains { existing in
                    let overlap = existing.rect.intersection(candidate)
                    return !overlap.isNull && overlap.width * overlap.height > 0.8 * candidate.width * candidate.height
                }
            }
            let noun = kind == .faces ? "face" : "text area"
            if found.isEmpty {
                notice = kind == .faces ? "No faces found." : "No text found."
            } else if fresh.isEmpty {
                notice = "Every \(noun) found is already covered."
            } else {
                pushUndo()
                regions += fresh.map { PhotoRedactRegion(rect: $0) }
                selectedID = nil
                notice = fresh.count == 1 ? "Added 1 \(noun)." : "Added \(fresh.count) \(noun)s."
            }
        }
    }
}

// MARK: - Canvas

final class PhotoRedactCanvasView: ImageCanvasNSView {
    weak var model: PhotoRedactModel?

    private enum Drag {
        case none
        case create(UUID, origin: CGPoint)
        case move(UUID, offset: CGVector, downAt: CGPoint, moved: Bool)
        case grip(UUID, ImageRectHandle)
    }

    private var drag: Drag = .none
    private var cacheKey: String?
    private var cachedPreview: CGImage?

    func modelDidChange() {
        guard let model else { return }
        displayImage = model.preview
        imageSize = model.imageSize
        showsCheckerboard = model.hasAlpha
        needsDisplay = true
    }

    /// The preview with every region redacted, re-rendered only when regions or style change.
    private func redactedPreview() -> CGImage? {
        guard let model, let preview = model.preview else { return nil }
        guard !model.regions.isEmpty else { return preview }
        let key = model.style.rawValue + model.regions.map { "\($0.rect)" }.joined(separator: "|")
        if key == cacheKey, let cachedPreview { return cachedPreview }
        let scale = CGFloat(preview.width) / max(model.imageSize.width, 1)
        let rects = model.regions.map { CGRect(x: $0.rect.minX * scale, y: $0.rect.minY * scale, width: $0.rect.width * scale, height: $0.rect.height * scale) }
        cachedPreview = PhotoRedactProcessor.apply(rects, style: model.style, to: preview) ?? preview
        cacheKey = key
        return cachedPreview
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let model, model.preview != nil else { return }
        drawBaseImage(redactedPreview(), context: context)
        for region in model.regions where region.id != model.selectedID {
            let rect = toView(region.rect).integral
            context.saveGState()
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.setShadow(offset: .zero, blur: 1.5, color: CGColor(gray: 0, alpha: 0.6))
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            context.restoreGState()
        }
        if let selected = model.selected {
            let rect = toView(selected.rect).integral
            drawSelectionOutline(rect, context: context)
            for handle in ImageRectHandle.allCases { drawGrip(at: handle.point(in: rect), context: context, radius: 4.5) }
        }
    }

    private func region(at point: CGPoint) -> PhotoRedactRegion? {
        model?.regions.last { $0.rect.insetBy(dx: -3 / viewScale, dy: -3 / viewScale).contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let model, model.preview != nil else { return }
        window?.makeFirstResponder(self)
        model.notice = nil
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = toImage(viewPoint)
        let bounds = CGRect(origin: .zero, size: imageSize)
        if let selected = model.selected, let grip = handle(at: viewPoint, of: selected.rect) {
            model.pushUndo()
            drag = .grip(selected.id, grip)
        } else if let hit = region(at: point) {
            model.selectedID = hit.id
            drag = .move(hit.id, offset: CGVector(dx: point.x - hit.rect.minX, dy: point.y - hit.rect.minY), downAt: viewPoint, moved: false)
        } else if imageRect.insetBy(dx: -6, dy: -6).contains(viewPoint) {
            let origin = CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
            model.pushUndo()
            let region = PhotoRedactRegion(rect: CGRect(origin: origin, size: .zero))
            model.regions.append(region)
            model.selectedID = region.id
            drag = .create(region.id, origin: origin)
        } else {
            model.selectedID = nil
            drag = .none
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = toImage(viewPoint)
        let bounds = CGRect(origin: .zero, size: imageSize)
        let minSize = 4 / max(viewScale, 0.0001)
        switch drag {
        case .none:
            return
        case .create(let id, let origin):
            let clamped = CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
            model.update(id, rect: ImageCanvasGeometry.rect(from: origin, to: clamped))
        case .move(let id, let offset, let downAt, let moved):
            guard let region = model.regions.first(where: { $0.id == id }) else { return }
            if !moved {
                guard ImageCanvasGeometry.distance(downAt, viewPoint) > 2.5 else { return }
                model.pushUndo()
            }
            let moved = CGRect(x: point.x - offset.dx, y: point.y - offset.dy, width: region.rect.width, height: region.rect.height)
            model.update(id, rect: ImageCanvasGeometry.clamp(moved, inside: bounds))
            drag = .move(id, offset: offset, downAt: downAt, moved: true)
            NSCursor.closedHand.set()
        case .grip(let id, let grip):
            guard let region = model.regions.first(where: { $0.id == id }) else { return }
            model.update(id, rect: grip.resize(region.rect, to: point, aspect: nil, minSize: minSize, bounds: bounds))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        if case .create(let id, _) = drag, let region = model.regions.first(where: { $0.id == id }),
           min(region.rect.width, region.rect.height) * viewScale < 4 {
            model.regions.removeAll { $0.id == id }
            model.selectedID = nil
            model.discardLastUndo()
        }
        drag = .none
        needsDisplay = true
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at viewPoint: CGPoint) {
        guard let model, model.preview != nil else { NSCursor.arrow.set(); return }
        if let selected = model.selected, let grip = handle(at: viewPoint, of: selected.rect) {
            grip.cursor.set()
        } else if region(at: toImage(viewPoint)) != nil {
            NSCursor.openHand.set()
        } else if imageRect.contains(viewPoint) {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            model?.deleteSelected()
        case 53:
            model?.selectedID = nil
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
        guard characters == "z", !shift, let model else { return false }
        model.undo()
        return true
    }
}

struct PhotoRedactCanvas: NSViewRepresentable {
    @ObservedObject var model: PhotoRedactModel

    func makeNSView(context: Context) -> PhotoRedactCanvasView {
        let view = PhotoRedactCanvasView()
        view.model = model
        model.canvas = view
        view.modelDidChange()
        return view
    }

    func updateNSView(_ view: PhotoRedactCanvasView, context: Context) {
        view.model = model
        view.modelDidChange()
    }
}

// MARK: - Editor

struct RedactPhotoEditor: View {
    @ObservedObject var session: ToolSession
    @StateObject private var model: PhotoRedactModel

    init(session: ToolSession, style: PhotoRedactStyle = .solid, seed: ((CGSize) -> [CGRect])? = nil,
         onLoad: ((PhotoRedactModel) -> Void)? = nil) {
        self.session = session
        let model = PhotoRedactModel(url: session.primaryURL)
        model.style = style
        model.seed = seed
        model.onLoad = onLoad
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ToolScaffold(session: session) {
            VStack(spacing: 0) {
                toolbar
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                Divider().opacity(0.4)
                canvas
            }
        } footer: {
            ToolFooter(session: session, primaryTitle: "Save Redacted Copy", primaryEnabled: model.preview != nil && !model.regions.isEmpty,
                       action: save) {
                HStack(spacing: 8) {
                    ImageToolTextButton(title: "Undo", symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { model.undo() }
                        .disabled(!model.canUndo)
                        .opacity(model.canUndo ? 1 : 0.45)
                    ImageToolTextButton(title: "Delete", symbol: "trash", help: "Delete the selected rectangle (⌫)") { model.deleteSelected() }
                        .disabled(model.selectedID == nil)
                        .opacity(model.selectedID == nil ? 0.45 : 1)
                    ImageToolTextButton(title: "Remove All", symbol: "xmark.square", help: "Remove every rectangle") { model.removeAll() }
                        .disabled(model.regions.isEmpty)
                        .opacity(model.regions.isEmpty ? 0.45 : 1)
                }
            }
        }
        .task { await model.load() }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Style").font(.system(size: 12)).foregroundStyle(.secondary)
                ToolSegmented(selection: $model.style, options: PhotoRedactStyle.allCases.map { ($0, $0.title) })
                Spacer(minLength: 12)
                Text("Auto-detect").font(.system(size: 12)).foregroundStyle(.secondary)
                ImageToolTextButton(title: "Faces", symbol: "person.crop.square", help: "Find faces and cover them") {
                    Task { await model.detect(.faces) }
                }
                .disabled(model.detecting != nil)
                ImageToolTextButton(title: "Text", symbol: "text.viewfinder", help: "Find text and cover it") {
                    Task { await model.detect(.text) }
                }
                .disabled(model.detecting != nil)
            }
            HStack(spacing: 6) {
                if model.detecting != nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: model.notice == nil ? "info.circle" : "checkmark.circle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(model.notice == nil ? Color.secondary : Brand.buttonOrange)
                }
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var hint: String {
        if let detecting = model.detecting { return detecting }
        if let notice = model.notice { return notice }
        if model.style == .blur { return "Blur softens details. Use Solid for sensitive information." }
        return "Draw a rectangle over the area to hide."
    }

    @ViewBuilder
    private var canvas: some View {
        if let error = model.loadError {
            ToolMessageView(symbol: "exclamationmark.triangle", message: error)
        } else if model.preview == nil {
            ToolMessageView(symbol: "photo", message: "Loading photo…", isLoading: true)
        } else {
            PhotoRedactCanvas(model: model)
                .background(Color.primary.opacity(0.035))
                .accessibilityLabel("Photo. Draw a rectangle over the area to hide.")
        }
    }

    private func save() {
        let regions = model.regions.map(\.rect)
        let size = model.imageSize
        let style = model.style
        session.runPerItem { url, context in
            try await PhotoRedactProcessor.process(url, regions: regions, imageSize: size, style: style, context: context)
        }
    }
}
