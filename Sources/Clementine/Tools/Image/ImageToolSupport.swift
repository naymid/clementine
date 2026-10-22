import AppKit
import CoreImage
import SwiftUI

// MARK: - Loading and saving

/// Loading, saving and drawing helpers shared by the image tool editors.
enum ImageToolIO {
    /// One Core Image context for previews and exports. CIContext is thread safe.
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Longest edge of the proxies editors draw while you work.
    static let previewPixels = 1600

    /// The format an edited copy is written in: the source's own format, or PNG for SVG and anything unknown.
    static func outputFormat(for url: URL, forcePNG: Bool = false) -> FileFormat {
        guard !forcePNG, let format = FileFormat.detect(url) else { return .png }
        switch format {
        case .jpg, .png, .webp, .heic, .tiff, .avif, .bmp: return format
        default: return .png
        }
    }

    static func quality(for format: FileFormat) -> Double? {
        switch format {
        case .jpg, .webp: return 0.92
        case .heic, .avif: return 0.9
        default: return nil
        }
    }

    /// Loads off the main thread.
    static func loadAsync(_ url: URL, maxPixel: Int? = nil) async throws -> ImageIOHelpers.LoadedImage {
        try await Task.detached(priority: .userInitiated) {
            try ImageIOHelpers.load(url, maxPixel: maxPixel)
        }.value
    }

    /// Pixel size of the upright image, without decoding it.
    static func uprightSize(of url: URL) -> CGSize? {
        if url.pathExtension.lowercased() == "svg" { return nil }
        return ImageIOHelpers.size(of: url)
    }

    /// Metadata worth carrying into an edited copy: orientation is baked in and dimensions change.
    static func carriedProperties(_ properties: [CFString: Any]) -> [CFString: Any] {
        var cleaned = properties
        cleaned[kCGImagePropertyPixelWidth] = nil
        cleaned[kCGImagePropertyPixelHeight] = nil
        cleaned[kCGImagePropertyOrientation] = 1
        if var exif = cleaned[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            cleaned[kCGImagePropertyExifDictionary] = exif
        }
        return cleaned
    }

    /// Writes `image` beside `source` in the source's format (PNG for SVG, or when `forcePNG`).
    /// With `stripMetadata` no EXIF, GPS, IPTC or XMP is written.
    @discardableResult
    static func save(_ image: CGImage, beside source: URL, suffix: String, forcePNG: Bool = false,
                     properties: [CFString: Any]? = nil, stripMetadata: Bool = false,
                     context: JobContext) async throws -> URL {
        let format = outputFormat(for: source, forcePNG: forcePNG)
        let sourceExtension = source.pathExtension
        let ext = (FileFormat.detect(source) == format && !sourceExtension.isEmpty) ? sourceExtension : format.outputExtension
        let output = FileNaming.output(beside: source, suffix: suffix, extension: ext)
        let carried = stripMetadata ? nil : properties.map(carriedProperties)
        context.progress(0.85)
        do {
            if format == .webp {
                let scratch = try FileNaming.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: scratch) }
                let png = scratch.appendingPathComponent("frame.png")
                try ImageIOHelpers.write(image, to: png, format: .png, quality: nil, properties: carried)
                var options = FormatOptions()
                options.preserveMetadata = !stripMetadata
                try await ImageConverter.writeWebP(source: png, format: .png, to: output, options: options,
                                                   context: context, qualityOverride: quality(for: .webp))
            } else {
                try ImageIOHelpers.write(image, to: output, format: format, quality: quality(for: format), properties: carried)
            }
        } catch {
            if case ProcessError.cancelled = error { throw error }
            guard format != .png else { throw error }
            // Some encoders (AVIF on older systems, WebP without cwebp) are missing: fall back to PNG.
            try? FileManager.default.removeItem(at: output)
            let fallback = FileNaming.output(beside: source, suffix: suffix, extension: "png")
            try ImageIOHelpers.write(image, to: fallback, format: .png, quality: nil, properties: carried)
            context.progress(1)
            return fallback
        }
        context.progress(1)
        return output
    }

    /// The image as a CIImage with pixels in their natural (y-up) orientation.
    static func ciImage(_ image: CGImage) -> CIImage {
        CIImage(cgImage: image)
    }

    static func render(_ image: CIImage, extent: CGRect? = nil, colorSpace: CGColorSpace? = nil) -> CGImage? {
        let rect = extent ?? image.extent
        let space = colorSpace?.model == .rgb ? colorSpace! : ImageToolDrawing.sRGB
        return ciContext.createCGImage(image, from: rect, format: .RGBA8, colorSpace: space)
    }
}

// MARK: - Drawing

enum ImageToolDrawing {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A bitmap context whose coordinates run top-down like the editors (origin top-left).
    static func makeCanvas(width: Int, height: Int, colorSpace: CGColorSpace? = nil) -> CGContext? {
        let space = colorSpace?.model == .rgb ? colorSpace! : sRGB
        let context = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ?? CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                         space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        return context
    }

    /// Draws a CGImage the right way up in a top-down context.
    static func drawUpright(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// The largest rect with the image's aspect ratio that fits `bounds`, centered.
    static func fitRect(for size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    /// The smallest rect with the image's aspect ratio that covers `bounds`, centered.
    static func fillRect(for size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    /// Light/dark checkerboard for transparent pixels.
    static func drawCheckerboard(in rect: CGRect, context: CGContext, cell: CGFloat = 8, dark: Bool = false) {
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(dark ? CGColor(gray: 0.30, alpha: 1) : CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.setFillColor(dark ? CGColor(gray: 0.38, alpha: 1) : CGColor(gray: 0.86, alpha: 1))
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : cell)
            while x < rect.maxX {
                context.fill(CGRect(x: x, y: y, width: cell, height: cell))
                x += cell * 2
            }
            y += cell
            row += 1
        }
        context.restoreGState()
    }

    /// Scale from user space to device pixels, so shadows (which ignore the CTM) scale with the drawing.
    static func deviceScale(of context: CGContext) -> CGFloat {
        let transform = context.userSpaceToDeviceSpaceTransform
        return max(0.0001, sqrt(transform.a * transform.a + transform.b * transform.b))
    }
}

// MARK: - Colors

/// A color stored as sRGB components so settings stay plain values.
struct ImageToolColor: Hashable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat = 1

    init(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha)
    }

    init(nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.sRGB) ?? NSColor.black
        self.init(color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
    }

    init(color: Color) {
        self.init(nsColor: NSColor(color))
    }

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(nsColor: nsColor) }

    func withAlpha(_ value: CGFloat) -> ImageToolColor {
        var copy = self
        copy.alpha = value
        return copy
    }

    /// Perceived brightness, for choosing a contrasting label color.
    var luminance: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    static let white = ImageToolColor(1, 1, 1)
    static let black = ImageToolColor(0, 0, 0)
}

// MARK: - Undo

/// A bounded stack of earlier states.
struct ImageToolUndoStack<State> {
    private(set) var states: [State] = []
    private var lastKey: String?
    var limit = 80

    var canUndo: Bool { !states.isEmpty }

    /// Saves `state`. Consecutive pushes with the same non-nil key (e.g. one slider drag) collapse into one step.
    mutating func push(_ state: State, coalescing key: String? = nil) {
        if let key, key == lastKey { return }
        lastKey = key
        states.append(state)
        if states.count > limit { states.removeFirst(states.count - limit) }
    }

    mutating func pop() -> State? {
        lastKey = nil
        return states.popLast()
    }

    mutating func breakCoalescing() { lastKey = nil }
}

// MARK: - Shared SwiftUI pieces

/// "Previewing the first of N", shown when several images share one set of settings.
struct ImagePreviewingNote: View {
    var count: Int

    var body: some View {
        if count > 1 {
            HStack(spacing: 5) {
                Image(systemName: "square.stack")
                    .font(.system(size: 11, weight: .medium))
                Text("Previewing the first of \(count)")
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(.secondary)
            .help("The same settings are applied to every image.")
        }
    }
}

/// Square icon button that can show a selected (orange) state.
struct ImageToolIconButton: View {
    var symbol: String
    var help: String
    var isSelected = false
    var size: CGFloat = 30
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.8))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Brand.buttonOrange : Color.primary.opacity(0.06))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Small bordered text button used in editor toolbars and footers.
struct ImageToolTextButton: View {
    var title: String
    var symbol: String?
    var help: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 12))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? title)
    }
}

/// A row of color swatches plus a custom color well.
struct ImageColorPalette: View {
    @Binding var selection: ImageToolColor
    var colors: [ImageToolColor] = ImageColorPalette.standard
    var swatchSize: CGFloat = 18

    static let standard: [ImageToolColor] = [
        ImageToolColor(hex: 0xFF3B30), ImageToolColor(hex: 0xFF9500), ImageToolColor(hex: 0xFFD60A),
        ImageToolColor(hex: 0x34C759), ImageToolColor(hex: 0x0A84FF), ImageToolColor(hex: 0xBF5AF2),
        ImageToolColor(hex: 0x000000), ImageToolColor(hex: 0xFFFFFF),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(colors, id: \.self) { color in
                Button {
                    selection = color.withAlpha(1)
                } label: {
                    Circle()
                        .fill(color.color)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                        .frame(width: swatchSize, height: swatchSize)
                        .padding(2.5)
                        .overlay(Circle().strokeBorder(Brand.buttonOrange, lineWidth: isSelected(color) ? 2 : 0))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(Self.name(of: color))
                .accessibilityLabel(Self.name(of: color))
            }
            ColorPicker("Custom color", selection: Binding(get: { selection.color },
                                                            set: { selection = ImageToolColor(color: $0) }),
                        supportsOpacity: false)
                .labelsHidden()
                .fixedSize()
                .help("Custom color")
        }
    }

    private func isSelected(_ color: ImageToolColor) -> Bool {
        abs(color.red - selection.red) < 0.01 && abs(color.green - selection.green) < 0.01 && abs(color.blue - selection.blue) < 0.01
    }

    static func name(of color: ImageToolColor) -> String {
        switch (Int(color.red * 255), Int(color.green * 255), Int(color.blue * 255)) {
        case (255, 59, 48): return "Red"
        case (255, 149, 0): return "Orange"
        case (255, 214, 10): return "Yellow"
        case (52, 199, 89): return "Green"
        case (10, 132, 255): return "Blue"
        case (191, 90, 242): return "Purple"
        case (0, 0, 0): return "Black"
        case (255, 255, 255): return "White"
        default: return "Color"
        }
    }
}

/// Checkerboard behind transparent previews.
struct ImageCheckerboard: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                ImageToolDrawing.drawCheckerboard(in: CGRect(origin: .zero, size: size), context: cg, cell: 8,
                                                  dark: colorScheme == .dark)
            }
        }
    }
}

/// A slider row with the title and value above the slider, for narrow sidebars.
/// Double-click the title to reset it to `defaultValue`.
struct ImageAdjustSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var defaultValue: Double = 0
    var format: (Double) -> String = { value in
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 6)
                Text(format(value))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(abs(value - defaultValue) < 0.5 ? .secondary : Brand.buttonOrange)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = defaultValue }
            .help("Double-click to reset \(title.lowercased())")
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}

/// A grouped card with a title and a trailing Reset button.
struct ImageResettableSection<Content: View>: View {
    var title: String
    var canReset: Bool
    var onReset: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ToolSection {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Reset", action: onReset)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(canReset ? Brand.buttonOrange : Color.secondary.opacity(0.6))
                    .disabled(!canReset)
                    .help("Reset \(title)")
            }
            content()
        }
    }
}

// MARK: - Option parsing for headless tests

/// Reads `key=value` options passed to `--tool-test`.
struct ImageToolOptions {
    var values: [String: String]

    init(_ values: [String: String]) { self.values = values }

    func double(_ key: String, _ fallback: Double) -> Double {
        values[key].flatMap(Double.init) ?? fallback
    }

    func int(_ key: String, _ fallback: Int) -> Int {
        values[key].flatMap(Int.init) ?? fallback
    }

    func string(_ key: String, _ fallback: String) -> String {
        values[key] ?? fallback
    }

    func bool(_ key: String, _ fallback: Bool) -> Bool {
        guard let value = values[key]?.lowercased() else { return fallback }
        return ["1", "true", "yes", "on"].contains(value)
    }

    /// "0.1,0.2,0.5,0.5" → CGRect.
    func rect(_ key: String) -> CGRect? {
        guard let parts = values[key]?.split(separator: ",").compactMap({ Double($0) }), parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    /// "ff8800" → color.
    func color(_ key: String) -> ImageToolColor? {
        guard let raw = values[key]?.replacingOccurrences(of: "#", with: ""), let hex = UInt32(raw, radix: 16) else { return nil }
        return ImageToolColor(hex: hex)
    }
}
