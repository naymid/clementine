import AppKit
import CoreImage
import SwiftUI

// MARK: - Settings

/// Slider values for Adjust Photo. Every value is 0 when untouched; most run -100…100.
struct PhotoAdjustments: Equatable {
    // Light
    var exposure = 0.0
    var brightness = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var whites = 0.0
    var blacks = 0.0
    // Color
    var temperature = 0.0
    var tint = 0.0
    var saturation = 0.0
    var vibrance = 0.0
    var hue = 0.0
    // Effects & detail
    var gamma = 0.0
    var clarity = 0.0
    var texture = 0.0
    var sharpness = 0.0
    var dehaze = 0.0
    var fade = 0.0
    var vignette = 0.0
    var grain = 0.0
    var noiseReduction = 0.0
    var blur = 0.0

    enum Group: String, CaseIterable, Identifiable {
        case light, color, effects
        var id: String { rawValue }
        var title: String {
            switch self {
            case .light: return "Light"
            case .color: return "Color"
            case .effects: return "Effects"
            }
        }
        var symbol: String {
            switch self {
            case .light: return "sun.max"
            case .color: return "paintpalette"
            case .effects: return "sparkles"
            }
        }
    }

    struct Control: Identifiable {
        var key: String
        var title: String
        var group: Group
        var range: ClosedRange<Double>
        var keyPath: WritableKeyPath<PhotoAdjustments, Double>
        var id: String { key }
    }

    static let controls: [Control] = [
        Control(key: "exposure", title: "Exposure", group: .light, range: -100...100, keyPath: \.exposure),
        Control(key: "brightness", title: "Brightness", group: .light, range: -100...100, keyPath: \.brightness),
        Control(key: "contrast", title: "Contrast", group: .light, range: -100...100, keyPath: \.contrast),
        Control(key: "highlights", title: "Highlights", group: .light, range: -100...100, keyPath: \.highlights),
        Control(key: "shadows", title: "Shadows", group: .light, range: -100...100, keyPath: \.shadows),
        Control(key: "whites", title: "Whites", group: .light, range: -100...100, keyPath: \.whites),
        Control(key: "blacks", title: "Blacks", group: .light, range: -100...100, keyPath: \.blacks),
        Control(key: "temperature", title: "Temperature", group: .color, range: -100...100, keyPath: \.temperature),
        Control(key: "tint", title: "Tint", group: .color, range: -100...100, keyPath: \.tint),
        Control(key: "saturation", title: "Saturation", group: .color, range: -100...100, keyPath: \.saturation),
        Control(key: "vibrance", title: "Vibrance", group: .color, range: -100...100, keyPath: \.vibrance),
        Control(key: "hue", title: "Hue", group: .color, range: -180...180, keyPath: \.hue),
        Control(key: "gamma", title: "Gamma", group: .effects, range: -100...100, keyPath: \.gamma),
        Control(key: "clarity", title: "Clarity", group: .effects, range: -100...100, keyPath: \.clarity),
        Control(key: "texture", title: "Texture", group: .effects, range: -100...100, keyPath: \.texture),
        Control(key: "sharpness", title: "Sharpness", group: .effects, range: 0...100, keyPath: \.sharpness),
        Control(key: "dehaze", title: "Dehaze", group: .effects, range: -100...100, keyPath: \.dehaze),
        Control(key: "fade", title: "Fade", group: .effects, range: 0...100, keyPath: \.fade),
        Control(key: "vignette", title: "Vignette", group: .effects, range: -100...100, keyPath: \.vignette),
        Control(key: "grain", title: "Grain", group: .effects, range: 0...100, keyPath: \.grain),
        Control(key: "noise", title: "Noise Reduction", group: .effects, range: 0...100, keyPath: \.noiseReduction),
        Control(key: "blur", title: "Blur", group: .effects, range: 0...100, keyPath: \.blur),
    ]

    static func controls(in group: Group) -> [Control] { controls.filter { $0.group == group } }

    var isIdentity: Bool { self == PhotoAdjustments() }

    func isDefault(_ group: Group) -> Bool {
        Self.controls(in: group).allSatisfy { self[keyPath: $0.keyPath] == 0 }
    }

    mutating func reset(_ group: Group) {
        for control in Self.controls(in: group) { self[keyPath: control.keyPath] = 0 }
    }

    /// Reads `exposure=40 contrast=-10 …` test options.
    init(options: [String: String] = [:]) {
        for control in Self.controls {
            if let value = options[control.key].flatMap(Double.init) {
                self[keyPath: control.keyPath] = min(control.range.upperBound, max(control.range.lowerBound, value))
            }
        }
    }
}

// MARK: - Processing

/// Applies PhotoAdjustments with Core Image. Spatial effects scale with the image,
/// so a small preview proxy looks like the full-resolution result.
enum PhotoAdjustProcessor {
    static func apply(_ a: PhotoAdjustments, to input: CIImage) -> CIImage {
        guard !a.isIdentity else { return input }
        let extent = input.extent
        let unit = max(extent.width, extent.height) / 1000
        func n(_ value: Double) -> Double { value / 100 }
        var image = input

        if a.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: n(a.exposure) * 2])
        }
        if a.temperature != 0 || a.tint != 0 {
            // A higher assumed source temperature warms the result; tint moves toward magenta.
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + n(a.temperature) * (a.temperature > 0 ? 3500 : 2200), y: n(a.tint) * 60),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if a.shadows != 0 || a.highlights < 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": n(a.shadows),
                "inputHighlightAmount": a.highlights < 0 ? 1 + n(a.highlights) * 0.7 : 1,
                kCIInputRadiusKey: max(1, 2.5 * unit),
            ])
        }
        if a.whites != 0 || a.blacks != 0 || a.fade != 0 || a.highlights > 0 {
            let whites = n(a.whites), blacks = n(a.blacks), fade = n(a.fade), lift = max(0, n(a.highlights))
            let y0 = max(0, blacks) * 0.14 + fade * 0.2
            let y1 = 0.25 + min(0, blacks) * 0.12 + max(0, blacks) * 0.06 + fade * 0.1
            let y2 = 0.5 + fade * 0.03 + lift * 0.02
            let y3 = 0.75 + max(0, whites) * 0.1 + min(0, whites) * 0.06 + lift * 0.1 - fade * 0.04
            let y4 = 1 + min(0, whites) * 0.16 - fade * 0.08
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: y0),
                "inputPoint1": CIVector(x: 0.25, y: y1),
                "inputPoint2": CIVector(x: 0.5, y: y2),
                "inputPoint3": CIVector(x: 0.75, y: min(y3, y4 - 0.01)),
                "inputPoint4": CIVector(x: 1, y: y4),
            ])
        }
        if a.brightness != 0 || a.contrast != 0 || a.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: n(a.brightness) * 0.25,
                kCIInputContrastKey: 1 + n(a.contrast) * (a.contrast > 0 ? 0.45 : 0.6),
                kCIInputSaturationKey: 1 + n(a.saturation),
            ])
        }
        if a.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": n(a.vibrance)])
        }
        if a.hue != 0 {
            image = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: a.hue * .pi / 180])
        }
        if a.gamma != 0 {
            image = image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": pow(2, -n(a.gamma))])
        }
        if a.dehaze != 0 {
            let amount = n(a.dehaze)
            image = image.clampedToExtent()
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 60 * unit, kCIInputIntensityKey: amount * 0.35])
                .cropped(to: extent)
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: -amount * 0.03,
                kCIInputContrastKey: 1 + amount * 0.18,
                kCIInputSaturationKey: 1 + amount * 0.22,
            ])
        }
        if a.noiseReduction > 0 {
            image = image.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.005 + n(a.noiseReduction) * 0.08,
                kCIInputSharpnessKey: 0.4,
            ])
        }
        if a.clarity != 0 {
            image = image.clampedToExtent()
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 22 * unit, kCIInputIntensityKey: n(a.clarity) * 0.7])
                .cropped(to: extent)
        }
        if a.texture != 0 {
            image = image.clampedToExtent()
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: max(0.8, 3 * unit), kCIInputIntensityKey: n(a.texture) * 0.9])
                .cropped(to: extent)
        }
        if a.sharpness > 0 {
            image = image.clampedToExtent()
                .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: n(a.sharpness) * 1.6,
                                                                   kCIInputRadiusKey: max(0.6, 1.6 * unit)])
                .cropped(to: extent)
        }
        if a.blur > 0 {
            image = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: n(a.blur) * 30 * unit])
                .cropped(to: extent)
        }
        if a.vignette != 0 {
            let radius = hypot(extent.width, extent.height) / 2
            image = image.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: radius * 0.92,
                kCIInputIntensityKey: n(a.vignette) * 0.95,
                "inputFalloff": 0.65,
            ])
        }
        if a.grain > 0 {
            let amount = n(a.grain) * 0.42
            let scale = max(1, 1.1 * unit)
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .applyingFilter("CIColorMatrix", parameters: [
                    // Monochrome noise centered on 50% gray, scaled by the amount.
                    "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0.5 - amount / 2, y: 0.5 - amount / 2, z: 0.5 - amount / 2, w: 1),
                ])
                .cropped(to: extent)
            let grained = noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            // Keep the original alpha (soft light over transparent pixels would make them gray).
            image = grained.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: image,
            ])
        }
        return image.cropped(to: extent)
    }

    /// Full-resolution render, saved beside the original with "-edited".
    static func process(_ url: URL, adjustments: PhotoAdjustments, context: JobContext) async throws -> [URL] {
        let loaded = try ImageIOHelpers.load(url)
        context.progress(0.2)
        try context.checkCancelled()
        let input = CIImage(cgImage: loaded.image)
        let output = apply(adjustments, to: input)
        guard let rendered = ImageToolIO.render(output, extent: input.extent, colorSpace: loaded.image.colorSpace) else {
            throw ImageError.writeFailed("Core Image could not render the adjusted photo.")
        }
        context.progress(0.7)
        let saved = try await ImageToolIO.save(rendered, beside: url, suffix: "-edited", properties: loaded.properties, context: context)
        return [saved]
    }
}

// MARK: - Preview model

@MainActor
final class PhotoAdjustModel: ObservableObject {
    let url: URL
    @Published var adjustments = PhotoAdjustments() {
        didSet { if adjustments != oldValue { scheduleRender() } }
    }
    @Published private(set) var original: CGImage?
    @Published private(set) var rendered: CGImage?
    @Published private(set) var hasAlpha = false
    @Published private(set) var loadError: String?
    @Published var showOriginal = false

    private var proxy: CIImage?
    private var isRendering = false
    private var needsRender = false
    private let renderQueue = DispatchQueue(label: "clementine.adjust-photo.render", qos: .userInteractive)

    init(url: URL) {
        self.url = url
    }

    func load() async {
        guard original == nil else { return }
        do {
            let loaded = try await ImageToolIO.loadAsync(url, maxPixel: ImageToolIO.previewPixels)
            original = loaded.image
            hasAlpha = loaded.hasAlpha
            proxy = CIImage(cgImage: loaded.image)
            rendered = loaded.image
            scheduleRender()
        } catch {
            loadError = error.localizedDescription
        }
    }

    var displayed: CGImage? { showOriginal ? original : (rendered ?? original) }

    /// Renders the latest settings; while a render is running, further changes coalesce into one more render.
    private func scheduleRender() {
        guard let proxy else { return }
        if isRendering {
            needsRender = true
            return
        }
        isRendering = true
        needsRender = false
        let adjustments = self.adjustments
        renderQueue.async { [weak self] in
            let output = PhotoAdjustProcessor.apply(adjustments, to: proxy)
            let image = ImageToolIO.render(output, extent: proxy.extent)
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

struct AdjustPhotoEditor: View {
    @ObservedObject var session: ToolSession
    @StateObject private var model: PhotoAdjustModel
    @State private var group: PhotoAdjustments.Group = .light

    init(session: ToolSession, initial: PhotoAdjustments = PhotoAdjustments(), group: PhotoAdjustments.Group = .light) {
        self.session = session
        let model = PhotoAdjustModel(url: session.primaryURL)
        model.adjustments = initial
        _model = StateObject(wrappedValue: model)
        _group = State(initialValue: group)
    }

    var body: some View {
        ToolScaffold(session: session) {
            HStack(spacing: 0) {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.5)
                sidebar
                    .frame(width: 284)
            }
        } footer: {
            ToolFooter(session: session, primaryTitle: "Save Edited Copy", primaryEnabled: model.original != nil, action: save) {
                HStack(spacing: 12) {
                    ImageToolTextButton(title: "Reset All", symbol: "arrow.counterclockwise", help: "Reset every adjustment") {
                        model.adjustments = PhotoAdjustments()
                    }
                    .disabled(model.adjustments.isIdentity)
                    .opacity(model.adjustments.isIdentity ? 0.5 : 1)
                    ImagePreviewingNote(count: session.urls.count)
                }
            }
        }
        .task { await model.load() }
    }

    private var preview: some View {
        VStack(spacing: 8) {
            ZStack {
                if let image = model.displayed {
                    let size = CGSize(width: image.width, height: image.height)
                    GeometryReader { proxy in
                        let rect = ImageToolDrawing.fitRect(for: size, in: CGRect(origin: .zero, size: proxy.size))
                        ZStack {
                            if model.hasAlpha {
                                ImageCheckerboard()
                                    .frame(width: rect.width, height: rect.height)
                            }
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: rect.width, height: rect.height)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        .position(x: rect.midX, y: rect.midY)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !model.showOriginal { model.showOriginal = true } }
                        .onEnded { _ in model.showOriginal = false })
                    .accessibilityLabel("Photo preview. Press and hold to see the original.")
                } else if let error = model.loadError {
                    ToolMessageView(symbol: "exclamationmark.triangle", message: error)
                } else {
                    ToolMessageView(symbol: "photo", message: "Loading photo…", isLoading: true)
                }
                if model.showOriginal {
                    VStack {
                        Text("Original")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.black.opacity(0.6)))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.top, 8)
                    .allowsHitTesting(false)
                }
            }
            HStack(spacing: 8) {
                compareButton
                Text(model.showOriginal ? "Showing the original" : "Press and hold the photo to compare with the original")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
    }

    private var compareButton: some View {
        Image(systemName: model.showOriginal ? "eye.fill" : "eye")
            .font(.system(size: 12, weight: .medium))
            .frame(width: 28, height: 24)
            .foregroundStyle(model.showOriginal ? Color.white : Color.primary.opacity(0.8))
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(model.showOriginal ? Brand.buttonOrange : Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !model.showOriginal { model.showOriginal = true } }
                .onEnded { _ in model.showOriginal = false })
            .help("Hold to show the original")
            .accessibilityLabel("Show original")
            .accessibilityAddTraits(.isButton)
    }

    private var sidebar: some View {
        VStack(spacing: 12) {
            Picker("", selection: $group) {
                ForEach(PhotoAdjustments.Group.allCases) { group in
                    Label(group.title, systemImage: group.symbol).tag(group)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.top, 14)
            ScrollView {
                ImageResettableSection(title: group.title, canReset: !model.adjustments.isDefault(group),
                                       onReset: { model.adjustments.reset(group) }) {
                    ForEach(PhotoAdjustments.controls(in: group)) { control in
                        ImageAdjustSlider(title: control.title,
                                          value: Binding(get: { model.adjustments[keyPath: control.keyPath] },
                                                         set: { model.adjustments[keyPath: control.keyPath] = $0 }),
                                          range: control.range,
                                          format: control.key == "hue" ? { "\(Int($0.rounded()))°" } : { value in
                                              let rounded = Int(value.rounded())
                                              return rounded > 0 ? "+\(rounded)" : "\(rounded)"
                                          })
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
    }

    private func save() {
        let adjustments = model.adjustments
        session.runPerItem { url, context in
            try await PhotoAdjustProcessor.process(url, adjustments: adjustments, context: context)
        }
    }
}
