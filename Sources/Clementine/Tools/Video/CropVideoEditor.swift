import SwiftUI

// MARK: - Processing

enum CropVideoProcessor {
    struct PixelRect: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    /// Even width and height inside the frame, as the encoders need.
    static func pixelRect(_ rect: CGRect, in size: CGSize) -> PixelRect {
        let frameWidth = max(2, Int(size.width))
        let frameHeight = max(2, Int(size.height))
        let width = max(2, min(frameWidth, Int(rect.width.rounded())) / 2 * 2)
        let height = max(2, min(frameHeight, Int(rect.height.rounded())) / 2 * 2)
        let x = max(0, min(frameWidth - width, Int(rect.minX.rounded())))
        let y = max(0, min(frameHeight - height, Int(rect.minY.rounded())))
        return PixelRect(x: x, y: y, width: width, height: height)
    }

    /// Crops to `rect`, given in display pixels (after rotation), and saves "<name>-cropped.<ext>".
    /// ffmpeg rotates frames upright before filtering, so display coordinates apply directly.
    static func crop(_ source: URL, rect: CGRect, context: JobContext) async throws -> URL {
        let info = try await VideoExport.probe(source)
        let crop = pixelRect(rect, in: info.displaySize)
        let output = VideoExport.output(for: source, suffix: "-cropped")
        var arguments = ["-i", source.path, "-map", "0:V:0", "-map", "0:a?",
                         "-vf", "crop=\(crop.width):\(crop.height):\(crop.x):\(crop.y)"]
        arguments += FFmpegTool.videoCodecArguments(for: output)
        arguments += info.hasAudio ? ["-c:a", "copy"] : ["-an"]
        arguments += ["-map_metadata", "0"] + VideoExport.containerArguments(for: output)
        try await VideoExport.run(arguments, output: output, duration: info.duration, context: context)
        return output
    }
}

enum VideoCropAspect: String, CaseIterable, Identifiable {
    case free, original, square, wide, tall, portrait, classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .square: return "Square"
        case .wide: return "16:9"
        case .tall: return "9:16"
        case .portrait: return "4:5"
        case .classic: return "4:3"
        }
    }

    /// Width / height, or nil for a free crop.
    func ratio(for size: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return size.height > 0 ? size.width / size.height : nil
        case .square: return 1
        case .wide: return 16 / 9
        case .tall: return 9 / 16
        case .portrait: return 4 / 5
        case .classic: return 4 / 3
        }
    }
}

// MARK: - Editor

struct CropVideoEditor: View {
    @ObservedObject var session: ToolSession
    var initialAspect: VideoCropAspect = .free

    @StateObject private var player = MediaPlayerModel()
    @State private var frame: CGImage?
    @State private var frameTime: Double = 0
    @State private var crop: CGRect = .zero
    @State private var aspect: VideoCropAspect = .free
    @State private var loadingFrame = true

    private var url: URL { session.primaryURL }
    private var frameSize: CGSize { player.info.displaySize }
    private var bounds: CGRect { CGRect(origin: .zero, size: frameSize) }
    private var ratio: CGFloat? { aspect.ratio(for: frameSize) }
    private var output: CropVideoProcessor.PixelRect { CropVideoProcessor.pixelRect(crop, in: frameSize) }
    private var isFullFrame: Bool {
        output.width >= Int(frameSize.width) / 2 * 2 && output.height >= Int(frameSize.height) / 2 * 2
    }

    var body: some View {
        ToolScaffold(session: session, subtitle: VideoText.subtitle(url, player.info)) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 10) {
                    canvas
                    HStack(spacing: 10) {
                        Image(systemName: "film")
                            .foregroundStyle(.secondary)
                        Text("Preview frame")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Slider(value: $frameTime, in: 0...max(player.duration, 0.01))
                            .disabled(player.duration <= 0)
                            .accessibilityLabel("Preview frame time")
                        Text(VideoText.time(frameTime))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                }
                sidebar
                    .frame(width: 236)
            }
            .padding(16)
            .background(VideoKeyMonitor(handler: handleKey))
        } footer: {
            ToolFooter(session: session, primaryTitle: "Save Cropped Copy",
                       primaryEnabled: frameSize.width > 0 && !isFullFrame, action: save) {
                if frameSize.width > 0 {
                    Text(verbatim: "\(VideoText.size(frameSize)) → \(VideoText.size(output.width, output.height))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            await player.load(url)
            aspect = initialAspect
            resetCrop()
        }
        .task(id: frameRequest) { await loadFrame() }
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            let videoRect = VideoGeometry.fit(frameSize, in: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 10, dy: 10))
            let mapping = VideoPixelMapping(frameSize: frameSize, videoRect: videoRect)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.85)
                if let frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .frame(width: videoRect.width, height: videoRect.height)
                        .offset(x: videoRect.minX, y: videoRect.minY)
                        .accessibilityHidden(true)
                }
                if frameSize.width > 0, crop.width > 0 {
                    let cropRect = mapping.viewRect(crop)
                    Path { path in
                        path.addRect(videoRect)
                        path.addRect(cropRect)
                    }
                    .fill(Color.black.opacity(0.58), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    VideoRectDrawLayer(mapping: mapping, ratio: ratio) { rect in
                        if rect.width >= 8, rect.height >= 8 { crop = rect }
                    }
                    VideoRectEditor(rect: crop, mapping: mapping, ratio: ratio, minimumSize: 16, showsGrid: true,
                                    accessibilityText: "Crop selection. Drag to reposition.") { rect in
                        crop = rect
                    }
                    sizeBadge(for: cropRect)
                }
                if loadingFrame && frame == nil {
                    ProgressView().controlSize(.small)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .frame(minWidth: 320, minHeight: 240)
    }

    private func sizeBadge(for rect: CGRect) -> some View {
        Text(verbatim: VideoText.size(output.width, output.height))
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .position(x: rect.midX, y: max(12, rect.minY - 14 < 12 ? rect.minY + 16 : rect.minY - 14))
            .allowsHitTesting(false)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolSection("Aspect Ratio") {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach([VideoCropAspect.free, .original, .square]) { aspectChip($0) }
                    }
                    HStack(spacing: 6) {
                        ForEach([VideoCropAspect.wide, .tall, .portrait, .classic]) { aspectChip($0) }
                    }
                }
            }
            ToolSection("Size") {
                HStack(spacing: 6) {
                    pixelField("Width", value: output.width) { setSize(width: CGFloat($0), height: nil) }
                    Text("×").foregroundStyle(.secondary)
                    pixelField("Height", value: output.height) { setSize(width: nil, height: CGFloat($0)) }
                    Text("px").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    pixelField("X", value: output.x) { setOrigin(x: CGFloat($0), y: nil) }
                    pixelField("Y", value: output.y) { setOrigin(x: nil, y: CGFloat($0)) }
                    Spacer(minLength: 0)
                }
                VideoHint("Keep the crop inside the video frame. Sizes are rounded to even pixels.")
            }
            HStack(spacing: 8) {
                Button {
                    crop = VideoRectMath.moved(CGRect(x: (frameSize.width - crop.width) / 2, y: (frameSize.height - crop.height) / 2,
                                                      width: crop.width, height: crop.height), by: .zero, within: bounds)
                } label: { Label("Center", systemImage: "align.horizontal.center") }
                Button {
                    aspect = .free
                    resetCrop()
                } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
            }
            .buttonStyle(VideoActionStyle())
            .disabled(frameSize.width <= 0)
            Spacer(minLength: 0)
            VideoHint("Drag inside the frame to draw a new crop. Arrow keys nudge it by one pixel, Shift by ten.")
        }
    }

    private func aspectChip(_ option: VideoCropAspect) -> some View {
        Button(option.title) { apply(option) }
            .buttonStyle(VideoChipStyle(selected: aspect == option))
            .help(option == .free ? "Any shape" : option == .original ? "Keep the video's shape" : "Crop to \(option.title)")
    }

    private func pixelField(_ title: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { value }, set: { set($0) }), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 62)
                .accessibilityLabel("\(title) in pixels")
        }
    }

    // MARK: Actions

    private func resetCrop() {
        guard frameSize.width > 0 else { return }
        if let ratio {
            crop = VideoRectMath.largest(ratio: ratio, in: bounds)
        } else {
            crop = bounds
        }
    }

    private func apply(_ option: VideoCropAspect) {
        aspect = option
        guard frameSize.width > 0 else { return }
        if let ratio = option.ratio(for: frameSize) {
            crop = VideoRectMath.largest(ratio: ratio, in: bounds, centeredOn: crop.width > 0 ? CGPoint(x: crop.midX, y: crop.midY) : nil)
        }
    }

    private func setSize(width: CGFloat?, height: CGFloat?) {
        guard frameSize.width > 0 else { return }
        var newWidth = width ?? crop.width
        var newHeight = height ?? crop.height
        if let ratio {
            if width != nil { newHeight = newWidth / ratio } else { newWidth = newHeight * ratio }
        }
        let shrink = min(1, frameSize.width / max(newWidth, 1), frameSize.height / max(newHeight, 1))
        newWidth = max(16, newWidth * shrink)
        newHeight = max(16, newHeight * shrink)
        let rect = CGRect(x: crop.midX - newWidth / 2, y: crop.midY - newHeight / 2, width: newWidth, height: newHeight)
        crop = VideoRectMath.moved(rect, by: .zero, within: bounds)
    }

    private func setOrigin(x: CGFloat?, y: CGFloat?) {
        var rect = crop
        if let x { rect.origin.x = x }
        if let y { rect.origin.y = y }
        crop = VideoRectMath.moved(rect, by: .zero, within: bounds)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard VideoKeyMonitor.arrowKeys.contains(event.keyCode), crop.width > 0 else { return false }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let delta: CGSize
        switch event.keyCode {
        case 123: delta = CGSize(width: -step, height: 0)
        case 124: delta = CGSize(width: step, height: 0)
        case 125: delta = CGSize(width: 0, height: step)
        default: delta = CGSize(width: 0, height: -step)
        }
        crop = VideoRectMath.moved(crop, by: delta, within: bounds)
        return true
    }

    // MARK: Frame preview

    private var frameRequest: String {
        "\(player.playableURL?.path ?? "-")|\(player.isLoading)|\((frameTime * 20).rounded() / 20)"
    }

    private func loadFrame() async {
        guard !player.isLoading else { return }
        if frame != nil { try? await Task.sleep(nanoseconds: 90_000_000) }
        guard !Task.isCancelled else { return }
        let time = min(frameTime, max(0, player.duration - 0.05))
        let image = await VideoFrames.frame(source: url, playable: player.playableURL, at: time, maxSize: 1280)
        guard !Task.isCancelled else { return }
        if let image { frame = image }
        loadingFrame = false
    }

    private func save() {
        let rect = crop
        session.runPerItem { url, context in
            [try await CropVideoProcessor.crop(url, rect: rect, context: context)]
        }
    }
}
