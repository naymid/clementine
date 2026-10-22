import AppKit
import SwiftUI

// MARK: - Settings

enum ImageCropAspect: String, CaseIterable, Identifiable {
    case free, original, square, r4x3, r3x2, r16x9, r9x16, r4x5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .square: return "Square"
        case .r4x3: return "4:3"
        case .r3x2: return "3:2"
        case .r16x9: return "16:9"
        case .r9x16: return "9:16"
        case .r4x5: return "4:5"
        }
    }

    /// Width / height in pixels for an image of `size`, or nil for a free crop.
    func ratio(for size: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return size.height > 0 ? size.width / size.height : nil
        case .square: return 1
        case .r4x3: return 4.0 / 3.0
        case .r3x2: return 3.0 / 2.0
        case .r16x9: return 16.0 / 9.0
        case .r9x16: return 9.0 / 16.0
        case .r4x5: return 4.0 / 5.0
        }
    }

    init?(option: String) {
        switch option.lowercased() {
        case "free": self = .free
        case "original": self = .original
        case "square", "1:1": self = .square
        case "4:3": self = .r4x3
        case "3:2": self = .r3x2
        case "16:9": self = .r16x9
        case "9:16": self = .r9x16
        case "4:5": self = .r4x5
        default: return nil
        }
    }
}

/// One image's crop: a rect in 0…1 units of the rotated image (top-down) and clockwise quarter turns.
struct ImageCropState: Equatable {
    var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var quarterTurns = 0

    var isIdentity: Bool { quarterTurns % 4 == 0 && rect == CGRect(x: 0, y: 0, width: 1, height: 1) }

    static func rotatedSize(_ size: CGSize, turns: Int) -> CGSize {
        turns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// The largest rect with `ratio` (in pixels) inside an image of `size`, centered on `center` (0…1 units).
    static func fitted(ratio: CGFloat, imageSize size: CGSize, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        var width = size.width, height = width / ratio
        if height > size.height {
            height = size.height
            width = height * ratio
        }
        let normalized = CGSize(width: width / size.width, height: height / size.height)
        let rect = CGRect(x: center.x - normalized.width / 2, y: center.y - normalized.height / 2,
                          width: normalized.width, height: normalized.height)
        return ImageCanvasGeometry.clamp(rect, inside: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

// MARK: - Processing

enum ImageCropProcessor {
    /// Rotates clockwise by quarter turns.
    static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let size = ImageCropState.rotatedSize(CGSize(width: image.width, height: image.height), turns: turns)
        guard let context = ImageToolDrawing.makeCanvas(width: Int(size.width), height: Int(size.height), colorSpace: image.colorSpace) else { return nil }
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: CGFloat(turns) * .pi / 2)
        context.interpolationQuality = .none
        ImageToolDrawing.drawUpright(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                                       width: CGFloat(image.width), height: CGFloat(image.height)), context: context)
        return context.makeImage()
    }

    /// Pixel rect for a normalized crop of an image of `size`, rounded and kept inside the image.
    static func pixelRect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        let x = (normalized.minX * size.width).rounded(), y = (normalized.minY * size.height).rounded()
        let maxX = (normalized.maxX * size.width).rounded(), maxY = (normalized.maxY * size.height).rounded()
        let rect = CGRect(x: x, y: y, width: max(1, maxX - x), height: max(1, maxY - y))
        return ImageCanvasGeometry.clamp(rect, inside: CGRect(origin: .zero, size: size))
    }

    static func crop(_ image: CGImage, state: ImageCropState) -> CGImage? {
        guard let rotated = rotate(image, quarterTurns: state.quarterTurns) else { return nil }
        let rect = pixelRect(state.rect, in: CGSize(width: rotated.width, height: rotated.height))
        if rect.width == CGFloat(rotated.width), rect.height == CGFloat(rotated.height) { return rotated }
        return rotated.cropping(to: rect)
    }

    static func process(_ url: URL, state: ImageCropState, context: JobContext) async throws -> [URL] {
        let loaded = try ImageIOHelpers.load(url)
        context.progress(0.3)
        guard let output = crop(loaded.image, state: state) else {
            throw ImageError.writeFailed("Could not crop \(url.lastPathComponent).")
        }
        context.progress(0.6)
        return [try await ImageToolIO.save(output, beside: url, suffix: "-cropped", properties: loaded.properties, context: context)]
    }
}

// MARK: - Model

@MainActor
final class ImageCropModel: ObservableObject {
    let urls: [URL]
    @Published private(set) var index = 0
    @Published private(set) var states: [ImageCropState]
    @Published private(set) var aspect: ImageCropAspect = .free
    /// "Use this crop, as the same share of each image, for every image".
    @Published private(set) var sharesCrop = false
    @Published private(set) var displayImage: CGImage?
    @Published private(set) var thumbnails: [Int: CGImage] = [:]
    @Published private(set) var loadError: String?
    @Published private(set) var hasAlpha = false

    private var sizes: [Int: CGSize] = [:]
    private var proxies: [Int: CGImage] = [:]
    /// Called once the first image has loaded (used by scripted snapshots).
    var onLoad: ((ImageCropModel) -> Void)?
    weak var canvas: ImageCropCanvasView?

    init(urls: [URL]) {
        self.urls = urls
        states = Array(repeating: ImageCropState(), count: urls.count)
    }

    var state: ImageCropState { states[index] }

    /// Full-resolution size of the current image as rotated.
    var imageSize: CGSize { ImageCropState.rotatedSize(sizes[index] ?? .zero, turns: state.quarterTurns) }

    var pixelRect: CGRect { ImageCropProcessor.pixelRect(state.rect, in: imageSize) }

    func load() async {
        await show(index: 0)
        onLoad?(self)
        for (offset, url) in urls.enumerated() where urls.count > 1 {
            if let thumb = try? await ImageToolIO.loadAsync(url, maxPixel: 160) { thumbnails[offset] = thumb.image }
        }
    }

    func show(index newIndex: Int) async {
        guard urls.indices.contains(newIndex) else { return }
        index = newIndex
        if proxies[newIndex] == nil {
            do {
                let loaded = try await ImageToolIO.loadAsync(urls[newIndex], maxPixel: ImageToolIO.previewPixels)
                proxies[newIndex] = loaded.image
                sizes[newIndex] = ImageToolIO.uprightSize(of: urls[newIndex]) ?? CGSize(width: loaded.image.width, height: loaded.image.height)
                hasAlpha = loaded.hasAlpha
                loadError = nil
            } catch {
                loadError = error.localizedDescription
                displayImage = nil
                return
            }
        }
        guard index == newIndex else { return }
        if sharesCrop { conformToAspect(at: newIndex) }
        refreshDisplay()
    }

    private func refreshDisplay() {
        guard let proxy = proxies[index] else { return }
        displayImage = ImageCropProcessor.rotate(proxy, quarterTurns: state.quarterTurns)
    }

    // MARK: Editing

    /// Sets the current crop (0…1 units). With a shared crop every image gets the same share.
    func setRect(_ rect: CGRect) {
        let clamped = ImageCanvasGeometry.clamp(rect, inside: CGRect(x: 0, y: 0, width: 1, height: 1))
        if sharesCrop {
            for offset in states.indices { states[offset].rect = clamped }
        } else {
            states[index].rect = clamped
        }
    }

    func setAspect(_ newAspect: ImageCropAspect) {
        aspect = newAspect
        conformToAspect(at: index)
        if sharesCrop { setRect(states[index].rect) }
    }

    /// Reshapes the crop at `offset` to the aspect ratio, keeping its center.
    private func conformToAspect(at offset: Int) {
        guard let size = sizes[offset] else { return }
        let rotated = ImageCropState.rotatedSize(size, turns: states[offset].quarterTurns)
        guard let ratio = aspect.ratio(for: rotated) else { return }
        let current = states[offset].rect
        let currentRatio = current.width * rotated.width / max(current.height * rotated.height, 0.0001)
        if abs(currentRatio - ratio) < 0.002 { return }
        let full = ImageCropState.fitted(ratio: ratio, imageSize: rotated, center: CGPoint(x: current.midX, y: current.midY))
        states[offset].rect = full
    }

    func setSharesCrop(_ value: Bool) {
        sharesCrop = value
        if value {
            let shared = states[index]
            for offset in states.indices { states[offset] = shared }
        }
    }

    func rotateClockwise() {
        let targets = sharesCrop ? Array(states.indices) : [index]
        for offset in targets {
            states[offset].quarterTurns = (states[offset].quarterTurns + 1) % 4
            let r = states[offset].rect
            // Turn the crop with the picture.
            states[offset].rect = CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
            conformToAspect(at: offset)
        }
        refreshDisplay()
    }

    func reset() {
        let targets = sharesCrop ? Array(states.indices) : [index]
        for offset in targets {
            states[offset] = ImageCropState()
            conformToAspect(at: offset)
        }
        refreshDisplay()
    }

    func setPixelWidth(_ width: Int) {
        let size = imageSize
        guard size.width > 0 else { return }
        var rect = state.rect
        let newWidth = min(max(1, CGFloat(width)), size.width) / size.width
        rect = CGRect(x: rect.midX - newWidth / 2, y: rect.minY, width: newWidth, height: rect.height)
        if let ratio = aspect.ratio(for: size) {
            var height = newWidth * size.width / ratio / size.height
            if height > 1 { height = 1; rect.size.width = ratio * size.height / size.width }
            rect = CGRect(x: rect.midX - rect.width / 2, y: state.rect.midY - height / 2, width: rect.width, height: height)
        }
        setRect(rect)
    }

    func setPixelHeight(_ height: Int) {
        let size = imageSize
        guard size.height > 0 else { return }
        var rect = state.rect
        let newHeight = min(max(1, CGFloat(height)), size.height) / size.height
        rect = CGRect(x: rect.minX, y: rect.midY - newHeight / 2, width: rect.width, height: newHeight)
        if let ratio = aspect.ratio(for: size) {
            var width = newHeight * size.height * ratio / size.width
            if width > 1 { width = 1; rect.size.height = size.width / ratio / size.height }
            rect = CGRect(x: state.rect.midX - width / 2, y: rect.midY - rect.height / 2, width: width, height: rect.height)
        }
        setRect(rect)
    }

    func stateByURL() -> [URL: ImageCropState] {
        Dictionary(zip(urls, states.indices.map { offset -> ImageCropState in
            guard sharesCrop, let size = sizes[offset] ?? ImageToolIO.uprightSize(of: urls[offset]) else { return states[offset] }
            // A shared crop is the same share of each image; keep a fixed aspect exact on every image.
            var state = states[offset]
            let rotated = ImageCropState.rotatedSize(size, turns: state.quarterTurns)
            if let ratio = aspect.ratio(for: rotated) {
                let current = state.rect
                let fitted = ImageCropState.fitted(ratio: ratio, imageSize: rotated, center: CGPoint(x: current.midX, y: current.midY))
                let scale = min(1, sqrt((current.width * current.height) / max(fitted.width * fitted.height, 0.0001)))
                state.rect = ImageCanvasGeometry.clamp(CGRect(x: current.midX - fitted.width * scale / 2, y: current.midY - fitted.height * scale / 2,
                                                              width: fitted.width * scale, height: fitted.height * scale),
                                                       inside: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return state
        }), uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - Canvas

/// Crop rectangle with eight grips, drag-to-move, a dimmed outside and a rule-of-thirds grid.
final class ImageCropCanvasView: ImageCanvasNSView {
    weak var model: ImageCropModel?

    private enum Drag {
        case none
        case grip(ImageRectHandle)
        case move(offset: CGVector)
        case draw(origin: CGPoint)
    }

    private var drag: Drag = .none
    private var isInteracting = false

    func modelDidChange() {
        guard let model else { return }
        displayImage = model.displayImage
        imageSize = model.imageSize
        showsCheckerboard = model.hasAlpha
        needsDisplay = true
    }

    /// Crop rect in image pixels.
    private var cropRect: CGRect {
        guard let model else { return .zero }
        let r = model.state.rect, size = model.imageSize
        return CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
    }

    private func setCrop(_ pixels: CGRect) {
        guard let model, imageSize.width > 0 else { return }
        model.setRect(CGRect(x: pixels.minX / imageSize.width, y: pixels.minY / imageSize.height,
                             width: pixels.width / imageSize.width, height: pixels.height / imageSize.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let model, model.displayImage != nil else { return }
        let imageRect = drawBaseImage(model.displayImage, context: context)
        let crop = toView(cropRect).integral.intersection(imageRect)

        // Dim outside the crop.
        context.saveGState()
        context.addRect(imageRect)
        context.addRect(crop)
        context.setFillColor(CGColor(gray: 0, alpha: 0.55))
        context.fillPath(using: .evenOdd)
        context.restoreGState()

        // Rule of thirds.
        context.saveGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: isInteracting ? 0.75 : 0.45))
        context.setLineWidth(0.75)
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            let x = crop.minX + crop.width * fraction, y = crop.minY + crop.height * fraction
            context.move(to: CGPoint(x: x, y: crop.minY)); context.addLine(to: CGPoint(x: x, y: crop.maxY))
            context.move(to: CGPoint(x: crop.minX, y: y)); context.addLine(to: CGPoint(x: crop.maxX, y: y))
        }
        context.strokePath()
        context.restoreGState()

        // Border.
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        context.setLineWidth(1)
        context.stroke(crop.insetBy(dx: 0.5, dy: 0.5))

        // Corner brackets and edge bars.
        context.saveGState()
        context.setShadow(offset: .zero, blur: 2, color: CGColor(gray: 0, alpha: 0.5))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(3.5)
        context.setLineCap(.square)
        let arm = min(18, crop.width / 3, crop.height / 3)
        let inset: CGFloat = 1.5
        let outer = crop.insetBy(dx: -inset, dy: -inset)
        for handle in ImageRectHandle.allCases {
            let point = handle.point(in: outer)
            switch handle {
            case .topLeft:
                context.move(to: CGPoint(x: point.x, y: point.y + arm)); context.addLine(to: point); context.addLine(to: CGPoint(x: point.x + arm, y: point.y))
            case .topRight:
                context.move(to: CGPoint(x: point.x - arm, y: point.y)); context.addLine(to: point); context.addLine(to: CGPoint(x: point.x, y: point.y + arm))
            case .bottomRight:
                context.move(to: CGPoint(x: point.x, y: point.y - arm)); context.addLine(to: point); context.addLine(to: CGPoint(x: point.x - arm, y: point.y))
            case .bottomLeft:
                context.move(to: CGPoint(x: point.x + arm, y: point.y)); context.addLine(to: point); context.addLine(to: CGPoint(x: point.x, y: point.y - arm))
            case .top, .bottom:
                context.move(to: CGPoint(x: point.x - arm / 2, y: point.y)); context.addLine(to: CGPoint(x: point.x + arm / 2, y: point.y))
            case .left, .right:
                context.move(to: CGPoint(x: point.x, y: point.y - arm / 2)); context.addLine(to: CGPoint(x: point.x, y: point.y + arm / 2))
            }
        }
        context.strokePath()
        context.restoreGState()

        if isInteracting {
            let rect = model.pixelRect
            drawSizeBadge("\(Int(rect.width)) × \(Int(rect.height))", below: crop, context: context)
        }
    }

    private func drawSizeBadge(_ text: String, below crop: CGRect, context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                         .foregroundColor: NSColor.white]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var badge = CGRect(x: crop.midX - size.width / 2 - 8, y: crop.maxY + 8, width: size.width + 16, height: size.height + 6)
        if badge.maxY > bounds.maxY - 2 { badge.origin.y = crop.maxY - badge.height - 8 }
        context.setFillColor(CGColor(gray: 0, alpha: 0.65))
        context.addPath(CGPath(roundedRect: badge, cornerWidth: badge.height / 2, cornerHeight: badge.height / 2, transform: nil))
        context.fillPath()
        string.draw(at: CGPoint(x: badge.minX + 8, y: badge.minY + 3))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let model, model.displayImage != nil else { return }
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = toImage(viewPoint)
        isInteracting = true
        if let grip = handle(at: viewPoint, of: cropRect) {
            drag = .grip(grip)
        } else if cropRect.contains(point) {
            drag = .move(offset: CGVector(dx: point.x - cropRect.minX, dy: point.y - cropRect.minY))
            NSCursor.closedHand.set()
        } else if imageRect.insetBy(dx: -8, dy: -8).contains(viewPoint) {
            let origin = CGPoint(x: min(max(point.x, 0), imageSize.width), y: min(max(point.y, 0), imageSize.height))
            drag = .draw(origin: origin)
        } else {
            drag = .none
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let point = toImage(convert(event.locationInWindow, from: nil))
        let bounds = CGRect(origin: .zero, size: imageSize)
        let ratio = model.aspect.ratio(for: imageSize)
        let minSize = max(16 / max(viewScale, 0.0001), 1)
        switch drag {
        case .none:
            return
        case .grip(let grip):
            setCrop(grip.resize(cropRect, to: point, aspect: ratio, minSize: minSize, bounds: bounds))
        case .move(let offset):
            let moved = CGRect(x: point.x - offset.dx, y: point.y - offset.dy, width: cropRect.width, height: cropRect.height)
            setCrop(ImageCanvasGeometry.clamp(moved, inside: bounds))
        case .draw(let origin):
            guard ImageCanvasGeometry.distance(origin, point) * viewScale > 3 else { return }
            // Drawing a new crop: treat it as dragging a corner away from the starting point.
            let handle: ImageRectHandle = point.x >= origin.x ? (point.y >= origin.y ? .bottomRight : .topRight)
                                                              : (point.y >= origin.y ? .bottomLeft : .topLeft)
            let seed = CGRect(origin: origin, size: .zero)
            setCrop(handle.resize(seed, to: point, aspect: ratio, minSize: minSize, bounds: bounds))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        drag = .none
        isInteracting = false
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
        guard model?.displayImage != nil else { NSCursor.arrow.set(); return }
        if let grip = handle(at: viewPoint, of: cropRect) {
            grip.cursor.set()
        } else if cropRect.contains(toImage(viewPoint)) {
            NSCursor.openHand.set()
        } else if imageRect.contains(viewPoint) {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: Keyboard: arrows nudge the crop

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = (event.modifierFlags.contains(.shift) ? 10 : 1)
        var delta = CGVector.zero
        switch event.keyCode {
        case 123: delta.dx = -step
        case 124: delta.dx = step
        case 125: delta.dy = step
        case 126: delta.dy = -step
        default:
            super.keyDown(with: event)
            return
        }
        let moved = cropRect.offsetBy(dx: delta.dx, dy: delta.dy)
        setCrop(ImageCanvasGeometry.clamp(moved, inside: CGRect(origin: .zero, size: imageSize)))
    }
}

struct ImageCropCanvas: NSViewRepresentable {
    @ObservedObject var model: ImageCropModel

    func makeNSView(context: Context) -> ImageCropCanvasView {
        let view = ImageCropCanvasView()
        view.model = model
        model.canvas = view
        view.modelDidChange()
        return view
    }

    func updateNSView(_ view: ImageCropCanvasView, context: Context) {
        view.model = model
        view.modelDidChange()
    }
}

// MARK: - Editor

struct CropImageEditor: View {
    @ObservedObject var session: ToolSession
    @StateObject private var model: ImageCropModel

    init(session: ToolSession, aspect: ImageCropAspect? = nil, onLoad: ((ImageCropModel) -> Void)? = nil) {
        self.session = session
        let model = ImageCropModel(urls: session.urls)
        model.onLoad = onLoad
        _model = StateObject(wrappedValue: model)
        initialAspect = aspect
    }

    private var initialAspect: ImageCropAspect?

    var body: some View {
        ToolScaffold(session: session, subtitle: subtitle) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    canvas
                    if session.urls.count > 1 {
                        Divider().opacity(0.4)
                        thumbnailStrip
                    }
                }
                Divider().opacity(0.5)
                sidebar
                    .frame(width: 270)
            }
        } footer: {
            ToolFooter(session: session, primaryTitle: session.urls.count > 1 ? "Save Cropped Copies" : "Save Cropped Copy",
                       primaryEnabled: model.displayImage != nil, action: save) {
                Text("Keep the crop inside the image.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await model.load()
            if let initialAspect { model.setAspect(initialAspect) }
        }
    }

    private var subtitle: String {
        session.urls.count > 1 ? "\(session.urls[model.index].lastPathComponent) · \(model.index + 1) of \(session.urls.count)" : session.subtitle
    }

    @ViewBuilder
    private var canvas: some View {
        if let error = model.loadError {
            ToolMessageView(symbol: "exclamationmark.triangle", message: error)
        } else if model.displayImage == nil {
            ToolMessageView(symbol: "photo", message: "Loading image…", isLoading: true)
        } else {
            ImageCropCanvas(model: model)
                .background(Color.primary.opacity(0.035))
                .accessibilityLabel("Crop area. Drag the corners or edges to crop, or drag inside to move the crop.")
        }
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(session.urls.enumerated()), id: \.offset) { offset, url in
                    Button {
                        Task { await model.show(index: offset) }
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08))
                            if let thumb = model.thumbnails[offset] {
                                Image(decorative: thumb, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            }
                        }
                        .frame(width: 56, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(offset == model.index ? Brand.buttonOrange : Color.primary.opacity(0.15),
                                          lineWidth: offset == model.index ? 2.5 : 0.5))
                        .overlay(alignment: .bottomTrailing) {
                            if !model.states[offset].isIdentity {
                                Image(systemName: "crop")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(3)
                                    .background(Circle().fill(Brand.buttonOrange))
                                    .padding(3)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(url.lastPathComponent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(height: 64)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ToolSection("Aspect ratio") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(ImageCropAspect.allCases) { aspect in
                            Button {
                                model.setAspect(aspect)
                            } label: {
                                Text(aspect.title)
                                    .font(.system(size: 11.5, weight: model.aspect == aspect ? .semibold : .regular))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .foregroundStyle(model.aspect == aspect ? Color.white : Color.primary.opacity(0.85))
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(model.aspect == aspect ? Brand.buttonOrange : Color.primary.opacity(0.07)))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(aspect == .free ? "Free crop" : "Crop to \(aspect.title)")
                        }
                    }
                }
                ToolSection("Size") {
                    HStack(spacing: 8) {
                        pixelField(title: "W", help: "Crop width in pixels", value: Int(model.pixelRect.width)) { model.setPixelWidth($0) }
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        pixelField(title: "H", help: "Crop height in pixels", value: Int(model.pixelRect.height)) { model.setPixelHeight($0) }
                    }
                    Text("of \(Int(model.imageSize.width)) × \(Int(model.imageSize.height)) pixels")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ToolSection {
                    HStack(spacing: 8) {
                        ImageToolTextButton(title: "Rotate", symbol: "rotate.right", help: "Rotate 90° clockwise") { model.rotateClockwise() }
                        ImageToolTextButton(title: "Reset", symbol: "arrow.counterclockwise", help: "Reset the crop and rotation") { model.reset() }
                    }
                    if session.urls.count > 1 {
                        Toggle(isOn: Binding(get: { model.sharesCrop }, set: { model.setSharesCrop($0) })) {
                            Text("Use this crop, as the same share of each image, for every image")
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .padding(14)
        }
    }

    private func pixelField(title: String, help: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { value }, set: { set($0) }), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 70)
                .help(help)
                .accessibilityLabel(help)
        }
    }

    private func save() {
        let states = model.stateByURL()
        session.runPerItem { url, context in
            try await ImageCropProcessor.process(url, state: states[url] ?? ImageCropState(), context: context)
        }
    }
}
