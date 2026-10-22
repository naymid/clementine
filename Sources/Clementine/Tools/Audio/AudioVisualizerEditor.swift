import AppKit
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Options

struct VisualizerOptions: Equatable {
    enum Style: String, CaseIterable, Hashable {
        case waveform, bars, image

        var title: String {
            switch self {
            case .waveform: return "Waveform"
            case .bars: return "Bars"
            case .image: return "Static image"
            }
        }
    }

    enum Canvas: String, CaseIterable, Hashable {
        case square, landscape, portrait

        var title: String { rawValue.capitalized }

        var size: (width: Int, height: Int) {
            switch self {
            case .square: return (1080, 1080)
            case .landscape: return (1920, 1080)
            case .portrait: return (1080, 1920)
            }
        }
    }

    enum Background: String, CaseIterable, Hashable {
        case black, color, image

        var title: String { rawValue.capitalized }
    }

    enum WaveColor: String, CaseIterable, Hashable {
        case white, orange, custom

        var title: String { rawValue.capitalized }
    }

    static let orangeHex = "ED6129"

    var style: Style = .waveform
    var waveColor: WaveColor = .white
    var customColorHex = "4FB3FF"
    var canvas: Canvas = .square
    var background: Background = .black
    var backgroundColorHex = "1C2333"
    var backgroundImage: URL?
    var stillImage: URL?

    var colorHex: String {
        switch waveColor {
        case .white: return "FFFFFF"
        case .orange: return Self.orangeHex
        case .custom: return customColorHex
        }
    }

    /// The image (if any) that becomes the video's backdrop.
    var backdropImage: URL? {
        switch style {
        case .image: return stillImage
        case .waveform, .bars: return background == .image ? backgroundImage : nil
        }
    }

    /// Whether everything needed to render is chosen.
    var isReady: Bool { style != .image || stillImage != nil }
}

// MARK: - Processing

enum AudioVisualizerProcessor {
    static let frameRate = 30
    static let barCount = 48

    /// Renders "<name>-visualizer.mp4" (H.264 + AAC) beside the audio.
    static func render(_ url: URL, options: VisualizerOptions, context: JobContext) async throws -> URL {
        guard options.isReady else { throw ProcessError.failed("Choose a static image for the visualization.") }
        let info = try await AudioStreamInfo.probe(url)
        let scratch = try FileNaming.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var backdrop: URL?
        if let image = options.backdropImage {
            let file = scratch.appendingPathComponent("backdrop.jpg")
            try await writeBackdropInBackground(image: image, canvas: options.canvas, foreground: options.style == .image, to: file)
            backdrop = file
        }
        let output = FileNaming.output(beside: url, suffix: "-visualizer", extension: "mp4")
        var arguments = ["-i", url.path]
        if let backdrop { arguments += ["-loop", "1", "-framerate", "\(frameRate)", "-i", backdrop.path] }
        arguments += ["-filter_complex", filterGraph(options: options, hasBackdrop: backdrop != nil, preview: false),
                      "-map", "[v]", "-map", "0:a:0",
                      "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", "-r", "\(frameRate)"]
        if options.style == .image { arguments += ["-tune", "stillimage"] }
        arguments += ["-c:a", "aac", "-b:a", "192k"]
        if info.duration > 0 { arguments += ["-t", AudioFFmpeg.number(info.duration)] }
        // Ogg and Opus keep their tags on the audio stream rather than the container.
        let tags = ["ogg", "oga", "opus"].contains(url.pathExtension.lowercased()) ? "0:s:a:0" : "0"
        arguments += ["-shortest", "-movflags", "+faststart", "-map_metadata", tags, "-color_range", "tv", output.path]
        do {
            try await AudioFFmpeg.run(arguments, duration: info.duration, context: context)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    /// One frame of the visualization at about a third of the way in, at half size, as PNG.
    static func renderPreviewFrame(_ url: URL, options: VisualizerOptions, duration: Double, backdrop: URL?,
                                   runner: ProcessRunner) async throws -> URL {
        let output = AudioScratch.file("png")
        let time = previewTime(duration: duration)
        var arguments = ["-ss", AudioFFmpeg.number(time), "-i", url.path]
        if let backdrop { arguments += ["-loop", "1", "-framerate", "\(frameRate)", "-i", backdrop.path] }
        arguments += ["-filter_complex", filterGraph(options: options, hasBackdrop: backdrop != nil, preview: true),
                      "-map", "[v]", "-frames:v", "1", "-update", "1", output.path]
        try await AudioFFmpeg.run(arguments, runner: runner)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw ProcessError.failed("The preview frame could not be drawn.")
        }
        return output
    }

    static func previewTime(duration: Double) -> Double {
        guard duration > 1 else { return 0 }
        return min(duration * 0.35, max(0, duration - 0.6))
    }

    /// Size of the waveform or bars area for the canvas.
    static func waveSize(_ canvas: VisualizerOptions.Canvas) -> (width: Int, height: Int) {
        let size = canvas.size
        let width = Int(Double(size.width) * 0.85) / 2 * 2
        let height: Int
        switch canvas {
        case .square: height = 420
        case .landscape: height = 460
        case .portrait: height = 560
        }
        return (width, height)
    }

    static func filterGraph(options: VisualizerOptions, hasBackdrop: Bool, preview: Bool) -> String {
        let size = options.canvas.size
        let tail = preview ? ",select='gte(n\\,5)',scale=iw/2:ih/2" : ""
        if options.style == .image {
            return "[1:v]scale=\(size.width):\(size.height):out_range=tv,setsar=1,format=yuv420p\(tail)[v]"
        }
        var chains: [String] = []
        if hasBackdrop {
            chains.append("[1:v]scale=\(size.width):\(size.height):out_range=tv,setsar=1,format=yuv420p[bg]")
        } else {
            let hex = options.background == .color ? options.backgroundColorHex : "000000"
            chains.append("color=c=0x\(hex):s=\(size.width)x\(size.height):r=\(frameRate)[bg]")
        }
        let wave = waveSize(options.canvas)
        switch options.style {
        case .waveform, .image:
            chains.append("[0:a]aformat=channel_layouts=mono,showwaves=s=\(wave.width)x\(wave.height):mode=cline:rate=\(frameRate)"
                          + ":colors=0x\(options.colorHex):scale=sqrt:draw=full,format=rgba[w]")
        case .bars:
            // Spectrum bars: showfreqs drawn as an alpha mask, grouped into chunky bars with gaps,
            // tinted with the chosen color and mirrored around the center line.
            let pitch = max(4, wave.width / barCount)
            let width = pitch * barCount
            let half = wave.height / 4 * 2
            let gap = max(2, pitch / 4)
            chains.append("color=c=0x\(options.colorHex):s=\(width)x\(half):r=\(frameRate)[col]")
            chains.append("[0:a]aformat=channel_layouts=mono,dynaudnorm=f=150:g=5,aresample=8000,"
                          + "showfreqs=s=\(width)x\(half):mode=bar:ascale=cbrt:fscale=log:win_size=1024:rate=\(frameRate):colors=white,"
                          + "format=gray,scale=\(barCount):\(half):flags=area,lut=y='if(gt(val\\,60)\\,255\\,0)',"
                          + "scale=\(width):\(half):flags=neighbor,drawgrid=x=0:y=-20:w=\(pitch):h=10000:t=\(gap):c=black[mask]")
            chains.append("[col][mask]alphamerge,split[top][bottom]")
            chains.append("[bottom]vflip[flipped]")
            chains.append("[top][flipped]vstack[w]")
        }
        chains.append("[bg][w]overlay=(W-w)/2:(H-h)/2:shortest=1,format=yuv420p\(tail)[v]")
        return chains.joined(separator: ";")
    }

    // MARK: Backdrops

    static func writeBackdropInBackground(image: URL, canvas: VisualizerOptions.Canvas, foreground: Bool, to output: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try writeBackdrop(image: image, canvas: canvas, foreground: foreground, to: output)
        }.value
    }

    /// Writes a canvas-sized JPEG: the image filling the frame, blurred and darkened, with the
    /// sharp image fitted on top when `foreground` is set (static image style).
    static func writeBackdrop(image url: URL, canvas: VisualizerOptions.Canvas, foreground: Bool, to output: URL) throws {
        guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]), !source.extent.isEmpty,
              source.extent.width.isFinite else {
            throw ProcessError.failed("This image could not be opened.")
        }
        let size = canvas.size
        let frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        func placed(_ scale: CGFloat) -> CIImage {
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return scaled.transformed(by: CGAffineTransform(translationX: frame.midX - scaled.extent.midX, y: frame.midY - scaled.extent.midY))
        }
        let extent = image.extent
        let cover = max(frame.width / extent.width, frame.height / extent.height)
        let blur = Double(min(frame.width, frame.height)) * (foreground ? 0.045 : 0.03)
        let black = CIImage(color: .black).cropped(to: frame)
        var result = placed(cover)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: blur)
            .cropped(to: frame)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: foreground ? -1.4 : -1.1])
            .composited(over: black)
        if foreground {
            let fit = min(frame.width * 0.84 / extent.width, frame.height * 0.84 / extent.height)
            result = placed(fit).composited(over: result)
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: colorSpace])
        guard let cgImage = context.createCGImage(result, from: frame, format: .RGBA8, colorSpace: colorSpace),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ProcessError.failed("The visualization background could not be drawn.") }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ProcessError.failed("The visualization background could not be saved.")
        }
    }
}

// MARK: - Model

@MainActor
final class AudioVisualizerModel: ObservableObject {
    let url: URL

    @Published var options: VisualizerOptions {
        didSet { if options != oldValue { refreshPreview(after: 0.25) } }
    }
    @Published private(set) var preview: NSImage?
    @Published private(set) var isRendering = false
    @Published private(set) var previewError: String?
    @Published private(set) var duration: Double = 0

    private var loaded = false
    private var backdrops: [String: URL] = [:]
    private let job = AudioEditorJob()

    init(url: URL, options: VisualizerOptions = VisualizerOptions()) {
        self.url = url
        self.options = options
    }

    deinit {
        for url in backdrops.values { try? FileManager.default.removeItem(at: url) }
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        duration = (try? await AudioStreamInfo.probe(url).duration) ?? 0
        refreshPreview()
    }

    func refreshPreview(after delay: Double = 0) {
        guard loaded else { return }
        let options = self.options
        guard options.isReady else {
            job.cancel()
            preview = nil
            previewError = nil
            isRendering = false
            return
        }
        isRendering = true
        let url = self.url
        let duration = self.duration
        job.start(after: delay) { [weak self] runner in
            guard let self else { return }
            do {
                let backdrop = try await self.backdrop(for: options)
                guard !runner.isCancelled else { return }
                let image: NSImage?
                if options.style == .image, let backdrop {
                    image = NSImage(contentsOf: backdrop)
                } else {
                    let frame = try await AudioVisualizerProcessor.renderPreviewFrame(url, options: options, duration: duration,
                                                                                      backdrop: backdrop, runner: runner)
                    image = NSImage(contentsOf: frame)
                    AudioScratch.remove(frame)
                }
                guard !runner.isCancelled else { return }
                self.preview = image
                self.previewError = image == nil ? "The preview could not be drawn. You can still create the visualization." : nil
                self.isRendering = false
            } catch {
                guard !runner.isCancelled else { return }
                self.previewError = (error as? LocalizedError)?.errorDescription ?? "The preview could not be drawn."
                self.isRendering = false
            }
        }
    }

    private func backdrop(for options: VisualizerOptions) async throws -> URL? {
        guard let image = options.backdropImage else { return nil }
        let key = "\(image.path)|\(options.canvas.rawValue)|\(options.style == .image)"
        if let cached = backdrops[key], FileManager.default.fileExists(atPath: cached.path) { return cached }
        let file = AudioScratch.file("jpg")
        try await AudioVisualizerProcessor.writeBackdropInBackground(image: image, canvas: options.canvas,
                                                                     foreground: options.style == .image, to: file)
        backdrops[key] = file
        return file
    }

    func chooseStillImage(window: NSWindow?) {
        AudioImagePicker.choose(message: "Choose a static image", window: window) { [weak self] url in
            self?.options.stillImage = url
        }
    }

    func chooseBackgroundImage(window: NSWindow?) {
        AudioImagePicker.choose(message: "Choose a visualization image", window: window) { [weak self] url in
            self?.options.backgroundImage = url
            self?.options.background = .image
        }
    }
}

// MARK: - Editor

struct AudioVisualizerEditor: View {
    @ObservedObject var session: ToolSession
    @StateObject private var model: AudioVisualizerModel

    init(session: ToolSession, options: VisualizerOptions = VisualizerOptions()) {
        self.session = session
        _model = StateObject(wrappedValue: AudioVisualizerModel(url: session.primaryURL, options: options))
    }

    var body: some View {
        ToolScaffold(session: session) {
            HStack(spacing: 0) {
                previewPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
                Divider().opacity(0.5)
                ScrollView {
                    settings
                        .padding(14)
                }
                .frame(width: 344)
            }
        } footer: {
            ToolFooter(session: session, primaryTitle: "Create Visualization", primaryEnabled: model.options.isReady) {
                let options = model.options
                session.runPerItem { url, context in
                    [try await AudioVisualizerProcessor.render(url, options: options, context: context)]
                }
            } leading: {
                let size = model.options.canvas.size
                AudioNote("MP4 · \(size.width) × \(size.height)\(model.duration > 0 ? " · \(FileNaming.formatTime(model.duration))" : "")",
                          symbol: "film")
            }
        }
        .task { await model.load() }
    }

    private var aspectRatio: CGFloat {
        let size = model.options.canvas.size
        return CGFloat(size.width) / CGFloat(size.height)
    }

    private var previewPane: some View {
        ZStack {
            if let preview = model.preview {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    .accessibilityLabel("Waveform visualization preview")
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.85))
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .overlay {
                        if model.options.style == .image && model.options.stillImage == nil {
                            VStack(spacing: 10) {
                                Image(systemName: "photo")
                                    .font(.system(size: 26, weight: .light))
                                    .foregroundStyle(.white.opacity(0.7))
                                Button("Choose a static image") { model.chooseStillImage(window: session.window) }
                                    .buttonStyle(FilledOrangeButtonStyle())
                            }
                        } else if let error = model.previewError {
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.75))
                                .multilineTextAlignment(.center)
                                .padding()
                        } else {
                            ProgressView().controlSize(.small).colorScheme(.dark)
                        }
                    }
                    .accessibilityLabel("Waveform visualization preview")
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.isRendering && model.preview != nil {
                ProgressView()
                    .controlSize(.mini)
                    .padding(6)
                    .background(Circle().fill(.regularMaterial))
                    .padding(8)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedImage(providers)
        }
        .help("Drop an image here to use it")
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolSection("Visualization style") {
                ToolSegmented(selection: $model.options.style, options: VisualizerOptions.Style.allCases.map { ($0, $0.title) })
                if model.options.style == .image {
                    imageChooser(title: "Choose a static image", url: model.options.stillImage) {
                        model.chooseStillImage(window: session.window)
                    }
                    AudioNote("The image stays on screen for the whole audio.")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Color")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ToolSegmented(selection: $model.options.waveColor, options: VisualizerOptions.WaveColor.allCases.map { ($0, $0.title) })
                            if model.options.waveColor == .custom {
                                ColorPicker("Waveform color", selection: hexBinding(\.customColorHex), supportsOpacity: false)
                                    .labelsHidden()
                                    .help("Choose the waveform color")
                            }
                        }
                    }
                    AudioNote(model.options.style == .waveform ? "An animated line that follows the sound." : "Animated bars for the sound’s frequencies.")
                }
            }
            ToolSection("Canvas") {
                ToolSegmented(selection: $model.options.canvas, options: VisualizerOptions.Canvas.allCases.map { ($0, $0.title) })
                let size = model.options.canvas.size
                AudioNote("\(size.width) × \(size.height) pixels")
            }
            if model.options.style != .image {
                ToolSection("Background") {
                    HStack(spacing: 8) {
                        ToolSegmented(selection: $model.options.background, options: VisualizerOptions.Background.allCases.map { ($0, $0.title) })
                        Spacer(minLength: 6)
                        if model.options.background == .color {
                            ColorPicker("Background color", selection: hexBinding(\.backgroundColorHex), supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                    if model.options.background == .image {
                        imageChooser(title: "Choose a visualization image", url: model.options.backgroundImage) {
                            model.chooseBackgroundImage(window: session.window)
                        }
                        AudioNote(model.options.backgroundImage == nil
                                  ? "Until you choose one, the background stays black."
                                  : "The image is blurred and darkened so the animation stands out.")
                    }
                }
            }
        }
    }

    private func imageChooser(title: String, url: URL?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                Label(url == nil ? title : "Change…", systemImage: "photo")
            }
            .buttonStyle(TintedButtonStyle())
            .help(title)
            if let url {
                Text(url.lastPathComponent)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func hexBinding(_ keyPath: WritableKeyPath<VisualizerOptions, String>) -> Binding<Color> {
        Binding(get: { Color(hexRGB: model.options[keyPath: keyPath]) ?? .white },
                set: { model.options[keyPath: keyPath] = $0.hexRGB })
    }

    private func loadDroppedImage(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return }
            DispatchQueue.main.async {
                if model.options.style == .image {
                    model.options.stillImage = url
                } else {
                    model.options.backgroundImage = url
                    model.options.background = .image
                }
            }
        }
        return true
    }
}
