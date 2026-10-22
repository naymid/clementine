import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Presets

/// A named background: a linear gradient with soft color blobs on top for a mesh-like look.
struct PhotoBackgroundPreset: Identifiable {
    struct Blob {
        var x: CGFloat
        var y: CGFloat
        var radius: CGFloat
        var color: UInt32
        var alpha: CGFloat = 0.9
    }

    let name: String
    let colors: [UInt32]
    /// Degrees; 90 runs top to bottom.
    let angle: CGFloat
    let blobs: [Blob]
    var id: String { name }

    var title: String { name.capitalized }

    static let gradients: [PhotoBackgroundPreset] = [
        PhotoBackgroundPreset(name: "citrus", colors: [0xFFC24B, 0xFF8A1F, 0xFF5A36], angle: 60, blobs: [
            Blob(x: 0.1, y: 0.05, radius: 0.55, color: 0xFFE66D), Blob(x: 0.95, y: 0.95, radius: 0.6, color: 0xFF4D6D, alpha: 0.75),
        ]),
        PhotoBackgroundPreset(name: "mesh", colors: [0xA18CD1, 0xFBC2EB], angle: 45, blobs: [
            Blob(x: 0.05, y: 0.1, radius: 0.6, color: 0xFF9A8B), Blob(x: 0.95, y: 0.15, radius: 0.55, color: 0x8FD3F4),
            Blob(x: 0.15, y: 0.95, radius: 0.55, color: 0xF6D365), Blob(x: 0.9, y: 0.9, radius: 0.6, color: 0x84FAB0, alpha: 0.8),
        ]),
        PhotoBackgroundPreset(name: "meadow", colors: [0xE3F988, 0x9BE15D, 0x2BB673], angle: 100, blobs: [
            Blob(x: 0.85, y: 0.1, radius: 0.5, color: 0xFFF6A5, alpha: 0.8), Blob(x: 0.1, y: 0.95, radius: 0.55, color: 0x0E9F6E, alpha: 0.6),
        ]),
        PhotoBackgroundPreset(name: "whisper", colors: [0xF8F9FB, 0xE9ECF2], angle: 90, blobs: [
            Blob(x: 0.1, y: 0.1, radius: 0.6, color: 0xFDE7EF, alpha: 0.9), Blob(x: 0.9, y: 0.85, radius: 0.6, color: 0xE3EEFF, alpha: 0.9),
        ]),
        PhotoBackgroundPreset(name: "orchid", colors: [0xF9A8D4, 0xC026D3, 0x7E22CE], angle: 50, blobs: [
            Blob(x: 0.1, y: 0.1, radius: 0.5, color: 0xFFD1E8, alpha: 0.85), Blob(x: 0.95, y: 0.95, radius: 0.55, color: 0x4C1D95, alpha: 0.6),
        ]),
        PhotoBackgroundPreset(name: "oasis", colors: [0xFDE7B0, 0x9DE0C8, 0x2AA198], angle: 120, blobs: [
            Blob(x: 0.9, y: 0.1, radius: 0.5, color: 0xFFF3D6, alpha: 0.9), Blob(x: 0.05, y: 0.9, radius: 0.55, color: 0x1F8A8A, alpha: 0.55),
        ]),
        PhotoBackgroundPreset(name: "lagoon", colors: [0x00C6D7, 0x0077B6, 0x023E8A], angle: 70, blobs: [
            Blob(x: 0.15, y: 0.1, radius: 0.55, color: 0x5EF2D6, alpha: 0.8), Blob(x: 0.9, y: 0.95, radius: 0.5, color: 0x03045E, alpha: 0.6),
        ]),
        PhotoBackgroundPreset(name: "aqua", colors: [0x9BF8F4, 0x6F86D6], angle: 75, blobs: [
            Blob(x: 0.1, y: 0.05, radius: 0.5, color: 0xD4FFFA, alpha: 0.9), Blob(x: 0.9, y: 0.9, radius: 0.5, color: 0x5B8DEF, alpha: 0.6),
        ]),
        PhotoBackgroundPreset(name: "dream", colors: [0xE0C3FC, 0x8EC5FC], angle: 40, blobs: [
            Blob(x: 0.9, y: 0.1, radius: 0.55, color: 0xFBC2EB, alpha: 0.9), Blob(x: 0.1, y: 0.9, radius: 0.5, color: 0xA6C1EE, alpha: 0.8),
        ]),
        PhotoBackgroundPreset(name: "sorbet", colors: [0xFFD3A5, 0xFF9A9E, 0xFD6585], angle: 55, blobs: [
            Blob(x: 0.1, y: 0.1, radius: 0.55, color: 0xFFF1B5, alpha: 0.85), Blob(x: 0.9, y: 0.85, radius: 0.5, color: 0xFAD0C4, alpha: 0.7),
        ]),
        PhotoBackgroundPreset(name: "frost", colors: [0xF4F9FF, 0xD9E8FB], angle: 90, blobs: [
            Blob(x: 0.85, y: 0.15, radius: 0.55, color: 0xFFFFFF, alpha: 0.9), Blob(x: 0.1, y: 0.95, radius: 0.55, color: 0xBFD9F6, alpha: 0.8),
        ]),
        PhotoBackgroundPreset(name: "emerald", colors: [0x34D399, 0x059669, 0x064E3B], angle: 65, blobs: [
            Blob(x: 0.1, y: 0.1, radius: 0.5, color: 0xA7F3D0, alpha: 0.7), Blob(x: 0.95, y: 0.95, radius: 0.55, color: 0x022C22, alpha: 0.6),
        ]),
        PhotoBackgroundPreset(name: "sunset", colors: [0xFDC830, 0xF37335, 0xC33764], angle: 95, blobs: [
            Blob(x: 0.85, y: 0.05, radius: 0.45, color: 0xFFF0A8, alpha: 0.75), Blob(x: 0.1, y: 1.0, radius: 0.6, color: 0x6A3093, alpha: 0.7),
        ]),
        PhotoBackgroundPreset(name: "sky", colors: [0x6EC1F5, 0xA8DBFA, 0xE6F6FF], angle: 90, blobs: [
            Blob(x: 0.85, y: 0.1, radius: 0.45, color: 0xFFFFFF, alpha: 0.55),
        ]),
        PhotoBackgroundPreset(name: "mint", colors: [0xD9FBE8, 0xA8E6CF, 0x7DD8C0], angle: 80, blobs: [
            Blob(x: 0.1, y: 0.1, radius: 0.5, color: 0xF1FFF8, alpha: 0.9), Blob(x: 0.9, y: 0.9, radius: 0.45, color: 0x8EE3EF, alpha: 0.6),
        ]),
        PhotoBackgroundPreset(name: "violet", colors: [0x8E2DE2, 0x4A00E0, 0x2B0A7A], angle: 60, blobs: [
            Blob(x: 0.1, y: 0.05, radius: 0.5, color: 0xC084FC, alpha: 0.7), Blob(x: 0.95, y: 0.95, radius: 0.5, color: 0x1E0752, alpha: 0.6),
        ]),
        PhotoBackgroundPreset(name: "graphite", colors: [0x4B5057, 0x2C3036, 0x16181C], angle: 80, blobs: [
            Blob(x: 0.15, y: 0.05, radius: 0.55, color: 0x6B717A, alpha: 0.6),
        ]),
    ]

    static let solids: [(name: String, color: UInt32)] = [
        ("white", 0xFFFFFF), ("yellow", 0xFFD60A), ("lime", 0xC5F24A), ("green", 0x34C759), ("teal", 0x30B0C7),
        ("cyan", 0x5AC8FA), ("cobalt", 0x1F5FD6), ("navy", 0x14234B), ("purple", 0xAF52DE), ("lavender", 0xC8B6F5),
        ("rose", 0xF7A1BF), ("red", 0xFF3B30), ("coral", 0xFF7F66), ("orange", 0xFF9500), ("brown", 0x8B5E3C),
        ("gray", 0x8E8E93), ("black", 0x000000),
    ]

    static func gradient(named name: String) -> PhotoBackgroundPreset? { gradients.first { $0.name == name } }
    static func solid(named name: String) -> ImageToolColor? { solids.first { $0.name == name }.map { ImageToolColor(hex: $0.color) } }

    /// Draws the preset filling `rect` (any coordinate orientation).
    func draw(in rect: CGRect, context: CGContext) {
        let space = ImageToolDrawing.sRGB
        context.saveGState()
        context.clip(to: rect)
        let cgColors = colors.map { ImageToolColor(hex: $0).cgColor } as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: nil) {
            let radians = angle * .pi / 180
            let half = (abs(cos(radians)) * rect.width + abs(sin(radians)) * rect.height) / 2
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let start = CGPoint(x: center.x - cos(radians) * half, y: center.y - sin(radians) * half)
            let end = CGPoint(x: center.x + cos(radians) * half, y: center.y + sin(radians) * half)
            context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let reach = max(rect.width, rect.height)
        for blob in blobs {
            let color = ImageToolColor(hex: blob.color)
            let colors = [color.withAlpha(blob.alpha).cgColor, color.withAlpha(blob.alpha * 0.45).cgColor, color.withAlpha(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.45, 1]) else { continue }
            let center = CGPoint(x: rect.minX + blob.x * rect.width, y: rect.minY + blob.y * rect.height)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: blob.radius * reach, options: [])
        }
        context.restoreGState()
    }
}

// MARK: - Settings

enum PhotoCanvasRatio: String, CaseIterable, Identifiable {
    case automatic, square, landscape, portrait
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .square: return "Square"
        case .landscape: return "Landscape"
        case .portrait: return "Portrait"
        }
    }

    /// Width / height, or nil to follow the image.
    var aspect: CGFloat? {
        switch self {
        case .automatic: return nil
        case .square: return 1
        case .landscape: return 16.0 / 9.0
        case .portrait: return 4.0 / 5.0
        }
    }
}

enum PhotoBackgroundFill: Equatable {
    case gradient(String)
    case solid(String)
    case custom(ImageToolColor)
    /// The photo itself, enlarged and blurred.
    case blurredPhoto
    /// Another image, enlarged and blurred.
    case image(URL)
}

struct PhotoBackgroundStyle: Equatable {
    var fill: PhotoBackgroundFill = .gradient("citrus")
    /// Percent of the image's longer side added around it.
    var padding: Double = 10
    /// Percent of the image's shorter side.
    var cornerRadius: Double = 3
    /// 0…100.
    var shadow: Double = 50
    var ratio: PhotoCanvasRatio = .automatic

    init() {}

    init(options: [String: String]) {
        let parse = ImageToolOptions(options)
        if let name = options["background"] {
            if PhotoBackgroundPreset.gradient(named: name) != nil { fill = .gradient(name) }
            else if PhotoBackgroundPreset.solid(named: name) != nil { fill = .solid(name) }
            else if name == "blur" || name == "photo" { fill = .blurredPhoto }
            else if let color = parse.color("background") { fill = .custom(color) }
            else if FileManager.default.fileExists(atPath: name) { fill = .image(URL(fileURLWithPath: name)) }
        }
        padding = parse.double("padding", padding)
        cornerRadius = parse.double("radius", cornerRadius)
        shadow = parse.double("shadow", shadow)
        ratio = PhotoCanvasRatio(rawValue: parse.string("ratio", ratio.rawValue)) ?? .automatic
    }
}

// MARK: - Rendering

enum PhotoBackgroundRenderer {
    /// Canvas size and the image's rect within it (top-down), for an image of `size`.
    static func layout(for size: CGSize, style: PhotoBackgroundStyle) -> (canvas: CGSize, imageRect: CGRect) {
        let pad = CGFloat(style.padding / 100) * max(size.width, size.height)
        var canvas = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
        if let aspect = style.ratio.aspect {
            if canvas.width / canvas.height < aspect {
                canvas.width = canvas.height * aspect
            } else {
                canvas.height = canvas.width / aspect
            }
        }
        canvas = CGSize(width: canvas.width.rounded(), height: canvas.height.rounded())
        let origin = CGPoint(x: ((canvas.width - size.width) / 2).rounded(), y: ((canvas.height - size.height) / 2).rounded())
        return (canvas, CGRect(origin: origin, size: size))
    }

    /// Renders `image` on its background. `backdrop` is the picture used by image fills (already loaded).
    static func render(_ image: CGImage, style: PhotoBackgroundStyle, backdrop: CGImage?) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let (canvasSize, imageRect) = layout(for: size, style: style)
        guard let context = ImageToolDrawing.makeCanvas(width: Int(canvasSize.width), height: Int(canvasSize.height)) else { return nil }
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        drawBackground(style.fill, in: canvasRect, context: context, photo: image, backdrop: backdrop)

        let longest = max(size.width, size.height)
        let radius = CGFloat(style.cornerRadius / 100) * min(size.width, size.height)
        let path = CGPath(roundedRect: imageRect, cornerWidth: min(radius, imageRect.width / 2), cornerHeight: min(radius, imageRect.height / 2), transform: nil)
        let shadow = CGFloat(style.shadow / 100)
        context.saveGState()
        if shadow > 0 {
            // Bitmap contexts keep shadows in device space (y up), so a negative height falls downward.
            context.setShadow(offset: CGSize(width: 0, height: -shadow * 0.018 * longest),
                              blur: shadow * 0.055 * longest,
                              color: CGColor(gray: 0, alpha: 0.18 + 0.32 * shadow))
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.addPath(path)
        context.clip()
        ImageToolDrawing.drawUpright(image, in: imageRect, context: context)
        context.endTransparencyLayer()
        context.restoreGState()
        return context.makeImage()
    }

    static func drawBackground(_ fill: PhotoBackgroundFill, in rect: CGRect, context: CGContext, photo: CGImage, backdrop: CGImage?) {
        switch fill {
        case .gradient(let name):
            (PhotoBackgroundPreset.gradient(named: name) ?? PhotoBackgroundPreset.gradients[0]).draw(in: rect, context: context)
        case .solid(let name):
            context.setFillColor((PhotoBackgroundPreset.solid(named: name) ?? .white).cgColor)
            context.fill(rect)
        case .custom(let color):
            context.setFillColor(color.withAlpha(1).cgColor)
            context.fill(rect)
        case .blurredPhoto, .image:
            let source: CGImage
            if case .image = fill, let backdrop { source = backdrop } else { source = photo }
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(rect)
            if let blurred = blurredBackdrop(source, filling: rect.size) {
                context.interpolationQuality = .high
                ImageToolDrawing.drawUpright(blurred, in: rect, context: context)
            }
        }
    }

    /// The picture scaled to cover `size`, heavily blurred. Rendered small (it's soft anyway) and scaled up.
    static func blurredBackdrop(_ image: CGImage, filling size: CGSize) -> CGImage? {
        let workLongest: CGFloat = 640
        let scale = min(1, workLongest / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let source = CIImage(cgImage: image)
        let fill = ImageToolDrawing.fillRect(for: source.extent.size, in: CGRect(origin: .zero, size: target))
        let transform = CGAffineTransform(translationX: fill.minX, y: target.height - fill.maxY)
            .scaledBy(x: fill.width / source.extent.width, y: fill.height / source.extent.height)
        let blurred = source.transformed(by: transform)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(target.width, target.height) * 0.07])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.2, kCIInputBrightnessKey: -0.04])
            .cropped(to: CGRect(origin: .zero, size: target))
        return ImageToolIO.render(blurred, extent: CGRect(origin: .zero, size: target))
    }

    /// Full-resolution export as PNG with "-background".
    static func process(_ url: URL, style: PhotoBackgroundStyle, context: JobContext) async throws -> [URL] {
        let loaded = try ImageIOHelpers.load(url)
        context.progress(0.2)
        var backdrop: CGImage?
        if case .image(let backgroundURL) = style.fill {
            backdrop = try? ImageIOHelpers.load(backgroundURL, maxPixel: 1600).image
        }
        try context.checkCancelled()
        guard let output = render(loaded.image, style: style, backdrop: backdrop) else {
            throw ImageError.writeFailed("Could not create the image with its background.")
        }
        context.progress(0.7)
        return [try await ImageToolIO.save(output, beside: url, suffix: "-background", forcePNG: true,
                                           properties: loaded.properties, context: context)]
    }
}

// MARK: - Preview model

@MainActor
final class PhotoBackgroundModel: ObservableObject {
    let url: URL
    @Published var style = PhotoBackgroundStyle() {
        didSet { if style != oldValue { scheduleRender() } }
    }
    @Published private(set) var rendered: CGImage?
    @Published private(set) var loadError: String?
    @Published private(set) var customColor = ImageToolColor(hex: 0xFFE8D6)

    private var proxy: CGImage?
    private var backdrop: CGImage?
    private var backdropURL: URL?
    private var isRendering = false
    private var needsRender = false
    private let queue = DispatchQueue(label: "clementine.background.render", qos: .userInteractive)

    init(url: URL) {
        self.url = url
    }

    func load() async {
        guard proxy == nil else { return }
        do {
            proxy = try await ImageToolIO.loadAsync(url, maxPixel: 1100).image
            scheduleRender()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func setCustomColor(_ color: ImageToolColor) {
        customColor = color
        style.fill = .custom(color)
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image background"
        panel.prompt = "Use as Background"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        Task {
            backdrop = try? await ImageToolIO.loadAsync(chosen, maxPixel: 1600).image
            backdropURL = chosen
            style.fill = .image(chosen)
            scheduleRender()
        }
    }

    var backgroundImageName: String? {
        if case .image(let url) = style.fill { return url.lastPathComponent }
        return nil
    }

    private func scheduleRender() {
        guard let proxy else { return }
        if isRendering {
            needsRender = true
            return
        }
        isRendering = true
        needsRender = false
        let style = self.style
        let backdrop = self.backdrop
        queue.async { [weak self] in
            let image = PhotoBackgroundRenderer.render(proxy, style: style, backdrop: backdrop)
            DispatchQueue.main.async {
                guard let self else { return }
                if let image { self.rendered = image }
                self.isRendering = false
                if self.needsRender { self.scheduleRender() }
            }
        }
    }
}

// MARK: - Editor

struct ChangeBackgroundEditor: View {
    @ObservedObject var session: ToolSession
    @StateObject private var model: PhotoBackgroundModel

    init(session: ToolSession) {
        self.session = session
        _model = StateObject(wrappedValue: PhotoBackgroundModel(url: session.primaryURL))
    }

    var body: some View {
        ToolScaffold(session: session) {
            HStack(spacing: 0) {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        backgroundSection
                        spacingSection
                    }
                    .padding(14)
                }
                .frame(width: 304)
            }
        } footer: {
            ToolFooter(session: session, primaryTitle: "Save with Background", primaryEnabled: model.rendered != nil, action: save) {
                ImagePreviewingNote(count: session.urls.count)
            }
        }
        .task { await model.load() }
    }

    private var preview: some View {
        Group {
            if let image = model.rendered {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                    .padding(22)
                    .accessibilityLabel("Preview of the photo on its new background")
            } else if let error = model.loadError {
                ToolMessageView(symbol: "exclamationmark.triangle", message: error)
            } else {
                ToolMessageView(symbol: "photo", message: "Loading photo…", isLoading: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.03))
    }

    private var backgroundSection: some View {
        ToolSection("Background") {
            Text("Gradients").font(.system(size: 11)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 3), count: 9), alignment: .leading, spacing: 4) {
                ForEach(PhotoBackgroundPreset.gradients) { preset in
                    swatch(isSelected: model.style.fill == .gradient(preset.name), help: preset.title) {
                        model.style.fill = .gradient(preset.name)
                    } content: {
                        PresetSwatch(preset: preset)
                    }
                }
            }
            Text("Colors").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 3), count: 9), alignment: .leading, spacing: 4) {
                ForEach(PhotoBackgroundPreset.solids, id: \.name) { solid in
                    let selected = model.style.fill == .solid(solid.name)
                    Button {
                        model.style.fill = .solid(solid.name)
                    } label: {
                        Circle()
                            .fill(ImageToolColor(hex: solid.color).color)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                            .frame(width: 19, height: 19)
                            .padding(2.5)
                            .overlay(Circle().strokeBorder(Brand.buttonOrange, lineWidth: selected ? 2 : 0))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(solid.name.capitalized)
                    .accessibilityLabel(solid.name.capitalized)
                }
            }
            ToolSettingRow("Custom background") {
                ColorPicker("Custom background", selection: Binding(get: { model.customColor.color },
                                                                    set: { model.setCustomColor(ImageToolColor(color: $0)) }),
                            supportsOpacity: false)
                    .labelsHidden()
                    .overlay(alignment: .trailing) {
                        if case .custom = model.style.fill {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.buttonOrange).offset(x: 20)
                        }
                    }
            }
            HStack(spacing: 8) {
                fillButton(title: "Blurred Photo", symbol: "drop", isSelected: model.style.fill == .blurredPhoto,
                           help: "Use the photo itself, enlarged and blurred") {
                    model.style.fill = .blurredPhoto
                }
                fillButton(title: model.backgroundImageName ?? "Choose Image…", symbol: "photo.on.rectangle",
                           isSelected: model.backgroundImageName != nil, help: "Choose an image background") {
                    model.chooseBackgroundImage()
                }
            }
        }
    }

    private var spacingSection: some View {
        ToolSection("Spacing & background") {
            ImageAdjustSlider(title: "Padding", value: $model.style.padding, range: 0...40, defaultValue: 10,
                              format: { "\(Int($0.rounded()))%" })
            ImageAdjustSlider(title: "Corner radius", value: $model.style.cornerRadius, range: 0...25, defaultValue: 3,
                              format: { "\(Int($0.rounded()))%" })
            ImageAdjustSlider(title: "Shadow", value: $model.style.shadow, range: 0...100, defaultValue: 50,
                              format: { "\(Int($0.rounded()))" })
            VStack(alignment: .leading, spacing: 6) {
                Text("Canvas ratio").font(.system(size: 12))
                Picker("Canvas ratio", selection: $model.style.ratio) {
                    ForEach(PhotoCanvasRatio.allCases) { ratio in
                        Text(ratio.title).tag(ratio)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
        }
    }

    private func swatch<Content: View>(isSelected: Bool, help: String, action: @escaping () -> Void,
                                       @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .frame(width: 21, height: 21)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .padding(2.5)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Brand.buttonOrange, lineWidth: isSelected ? 2 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func fillButton(title: String, symbol: String, isSelected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? Brand.buttonOrange : Color.primary.opacity(0.85))
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Brand.buttonOrange.opacity(0.14) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Brand.buttonOrange, lineWidth: isSelected ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func save() {
        let style = model.style
        session.runPerItem { url, context in
            try await PhotoBackgroundRenderer.process(url, style: style, context: context)
        }
    }
}

/// A small rendering of a gradient preset.
private struct PresetSwatch: View {
    let preset: PhotoBackgroundPreset

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                preset.draw(in: CGRect(origin: .zero, size: size), context: cg)
            }
        }
    }
}
