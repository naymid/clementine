import AppKit
import AVFoundation
import SwiftUI

// Shared pieces for the video editors. Everything here is prefixed with
// `Video` so it cannot collide with helpers from the other tool groups.

// MARK: - Export helpers

enum VideoExport {
    /// A free file beside `source` with the same container, e.g. "clip-trimmed.mp4".
    static func output(for source: URL, suffix: String) -> URL {
        FileNaming.output(beside: source, suffix: suffix, extension: source.pathExtension)
    }

    /// Muxer options for the output container.
    static func containerArguments(for output: URL) -> [String] {
        switch output.pathExtension.lowercased() {
        case "mp4", "m4v", "mov": return ["-movflags", "+faststart"]
        default: return []
        }
    }

    /// Rounds the frame size down to even numbers, which yuv420p encoders need.
    static let evenSize = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    /// Probes the file and fails clearly when it has no video.
    static func probe(_ url: URL) async throws -> MediaInfo {
        let info = try await MediaInfo.probe(url)
        guard info.hasVideo else { throw ProcessError.failed("\(url.lastPathComponent) has no video track.") }
        return info
    }

    /// Runs ffmpeg into `output` with HUD progress, deleting the partial file on failure.
    /// A sub-range maps this run's progress into part of the job, for multi-step exports.
    static func run(_ arguments: [String], output: URL, duration: Double, context: JobContext,
                    progress range: ClosedRange<Double> = 0...1) async throws {
        do {
            if range == 0...1 {
                try await FFmpegTool.run(arguments + [output.path], duration: duration, context: context)
            } else {
                guard let ffmpeg = ToolPaths.ffmpeg else { throw ProcessError.missingTool("ffmpeg") }
                try await MediaConverter.run(ffmpeg, ["-y", "-hide_banner", "-nostdin"] + arguments + [output.path],
                                             duration: duration, context: context, progressRange: range)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Seconds for ffmpeg arguments, e.g. "12.345".
    static func seconds(_ value: Double) -> String {
        String(format: "%.3f", max(0, value.isFinite ? value : 0))
    }

    /// A compact number for filter expressions, e.g. "0.5" or "29.97".
    static func number(_ value: Double) -> String {
        String(format: "%.6g", value)
    }

    /// The source frame rate, or 30 when ffprobe reported something unusable.
    static func frameRate(_ info: MediaInfo) -> Double {
        let rate = info.frameRate
        return rate.isFinite && rate >= 1 && rate <= 240 ? rate : 30
    }
}

// MARK: - Frames and thumbnails

enum VideoFrames {
    /// Evenly spaced thumbnails. Uses AVFoundation on the playable (or proxy) file,
    /// and ffmpeg on the original when AVFoundation cannot read it.
    static func thumbnails(source: URL, playable: URL?, duration: Double, count: Int, height: CGFloat = 90) async -> [CGImage] {
        if let playable {
            let images = await ThumbnailLoader.thumbnails(for: playable, count: count, maxHeight: height)
            if !images.isEmpty { return images }
        }
        guard duration > 0, count > 0 else { return [] }
        var images: [CGImage] = []
        for index in 0..<count {
            let seconds = duration * (Double(index) + 0.5) / Double(count)
            if let image = await ffmpegFrame(source, at: seconds, maxHeight: Int(height)) { images.append(image) }
        }
        return images
    }

    /// One display-oriented frame at `seconds`, trying AVFoundation first, then ffmpeg.
    static func frame(source: URL, playable: URL?, at seconds: Double, maxSize: CGFloat) async -> CGImage? {
        if let playable,
           let image = await ThumbnailLoader.frame(for: playable, at: max(0, seconds), maxSize: CGSize(width: maxSize, height: maxSize)) {
            return image
        }
        return await ffmpegFrame(source, at: seconds, maxHeight: Int(maxSize))
    }

    /// Decodes one frame with ffmpeg (autorotated) and returns it as an image.
    static func ffmpegFrame(_ url: URL, at seconds: Double, maxHeight: Int) async -> CGImage? {
        guard let ffmpeg = ToolPaths.ffmpeg else { return nil }
        let arguments = ["-v", "error", "-ss", VideoExport.seconds(seconds), "-i", url.path, "-map", "0:V:0", "-frames:v", "1",
                         "-vf", "scale=-2:'min(\(maxHeight),ih)'", "-f", "image2pipe", "-c:v", "png", "-"]
        guard let result = try? await ProcessRunner().run(ffmpeg, arguments), !result.stdout.isEmpty,
              let source = CGImageSourceCreateWithData(result.stdout as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: - Geometry

enum VideoGeometry {
    /// The aspect-fit rectangle of `content` inside `bounds`.
    static func fit(_ content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}

enum VideoText {
    /// "clip.mp4 · 640 × 360 · 0:03" once the file is probed.
    static func subtitle(_ url: URL, _ info: MediaInfo) -> String {
        guard info.hasVideo else { return url.lastPathComponent }
        let size = info.displaySize
        return "\(url.lastPathComponent) · \(Int(size.width)) × \(Int(size.height)) · \(FileNaming.formatTime(info.duration))"
    }

    /// "0:12.40"
    static func time(_ seconds: Double) -> String {
        FileNaming.formatTime(seconds, showsFraction: true)
    }

    /// "1.50 s"
    static func length(_ seconds: Double) -> String {
        String(format: "%.2f s", max(0, seconds))
    }

    /// "1280 × 720", without digit grouping.
    static func size(_ width: Int, _ height: Int) -> String {
        "\(String(width)) × \(String(height))"
    }

    static func size(_ size: CGSize) -> String {
        self.size(Int(size.width), Int(size.height))
    }
}

// MARK: - Stage

/// The black video area: the player (or a still frame when playback is
/// unavailable), loading and unavailable states, and an overlay that is told
/// where the video is drawn.
struct VideoStage<Overlay: View>: View {
    @ObservedObject var player: MediaPlayerModel
    var source: URL
    var overlay: (_ videoRect: CGRect) -> Overlay

    @State private var still: CGImage?

    init(player: MediaPlayerModel, source: URL, @ViewBuilder overlay: @escaping (_ videoRect: CGRect) -> Overlay) {
        self.player = player
        self.source = source
        self.overlay = overlay
    }

    var body: some View {
        GeometryReader { proxy in
            let videoRect = VideoGeometry.fit(player.info.displaySize, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                Color.black
                if player.playableURL != nil {
                    PlayerSurface(player: player.player)
                } else if let still {
                    Image(decorative: still, scale: 1)
                        .resizable()
                        .frame(width: videoRect.width, height: videoRect.height)
                        .offset(x: videoRect.minX, y: videoRect.minY)
                }
                overlay(videoRect)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                if player.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                if let message = player.unavailableMessage {
                    VStack {
                        Spacer()
                        VideoBanner(text: message, symbol: "exclamationmark.triangle")
                            .padding(10)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
                }
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .task(id: stillRequest) { await loadStill() }
    }

    /// Re-requested as the playhead moves, only while playback is unavailable.
    private var stillRequest: Double {
        guard player.playableURL == nil, !player.isLoading else { return -1 }
        return (player.currentTime * 10).rounded() / 10
    }

    private func loadStill() async {
        let request = stillRequest
        guard request >= 0 else { return }
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        if let image = await VideoFrames.ffmpegFrame(source, at: request, maxHeight: 720), !Task.isCancelled {
            still = image
        }
    }
}

extension VideoStage where Overlay == EmptyView {
    init(player: MediaPlayerModel, source: URL) {
        self.init(player: player, source: source) { _ in EmptyView() }
    }
}

/// A small dark capsule with a message, drawn over video.
struct VideoBanner: View {
    var text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(2).multilineTextAlignment(.center)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.62)))
    }
}

// MARK: - Timeline

/// Maps between time and x position on a timeline with side insets.
struct VideoTimelineMetrics {
    static let inset: CGFloat = 8

    var width: CGFloat
    var duration: Double
    var inset: CGFloat = VideoTimelineMetrics.inset

    var usable: CGFloat { max(1, width - inset * 2) }

    func x(_ time: Double) -> CGFloat {
        inset + CGFloat(max(0, min(time, duration)) / max(duration, 0.001)) * usable
    }

    func time(_ x: CGFloat) -> Double {
        max(0, min(duration, Double((x - inset) / usable) * duration))
    }

    /// Seconds per point, for converting drag distances.
    var secondsPerPoint: Double { duration / Double(usable) }
}

/// Thumbnails with a playhead: drag to scrub, click to place the playhead.
/// The overlay draws on top using the same metrics (markers, clips, ranges).
struct VideoThumbnailTimeline<Overlay: View>: View {
    var thumbnails: [CGImage]
    var duration: Double
    var playhead: Double
    var onScrub: (Double) -> Void
    var onClick: ((Double) -> Void)?
    var overlay: (VideoTimelineMetrics, CGFloat) -> Overlay

    init(thumbnails: [CGImage], duration: Double, playhead: Double,
         onScrub: @escaping (Double) -> Void, onClick: ((Double) -> Void)? = nil,
         @ViewBuilder overlay: @escaping (VideoTimelineMetrics, CGFloat) -> Overlay) {
        self.thumbnails = thumbnails
        self.duration = duration
        self.playhead = playhead
        self.onScrub = onScrub
        self.onClick = onClick
        self.overlay = overlay
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = VideoTimelineMetrics(width: proxy.size.width, duration: duration)
            ZStack(alignment: .topLeading) {
                ThumbnailStrip(images: thumbnails)
                    .frame(width: metrics.usable, height: proxy.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .offset(x: metrics.inset)
                overlay(metrics, proxy.size.height)
                Capsule()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.55), radius: 1.5)
                    .frame(width: 3, height: proxy.size.height + 8)
                    .offset(x: metrics.x(playhead) - 1.5, y: -4)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in onScrub(metrics.time(value.location.x)) }
                .onEnded { value in
                    if abs(value.translation.width) < 3 { onClick?(metrics.time(value.location.x)) }
                })
        }
        .help("Play or pause the timeline preview (Space)")
    }
}

extension VideoThumbnailTimeline where Overlay == EmptyView {
    init(thumbnails: [CGImage], duration: Double, playhead: Double, onScrub: @escaping (Double) -> Void) {
        self.init(thumbnails: thumbnails, duration: duration, playhead: playhead, onScrub: onScrub) { _, _ in EmptyView() }
    }
}

// MARK: - Keyboard

/// Sees key presses in the editor's window before buttons do, so Return and
/// Delete can mean "add frame" or "remove clip" instead of the default button.
/// Keys typed into text fields are left alone. Return true from the handler to
/// consume the key.
struct VideoKeyMonitor: NSViewRepresentable {
    var handler: (NSEvent) -> Bool

    static let returnKeys: Set<UInt16> = [36, 76]
    static let deleteKeys: Set<UInt16> = [51, 117]
    static let arrowKeys: Set<UInt16> = [123, 124, 125, 126]

    final class MonitorView: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                nonisolated(unsafe) let key = event
                let consume = MainActor.assumeIsolated { self?.consumes(key) ?? false }
                return consume ? nil : event
            }
        }

        /// Local monitors run on the main thread.
        private func consumes(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.isKeyWindow else { return false }
            if window.firstResponder is NSText {
                // Return commits the field instead of also pressing the save button.
                if VideoKeyMonitor.returnKeys.contains(event.keyCode) {
                    window.makeFirstResponder(nil)
                    return true
                }
                return false
            }
            return handler?(event) == true
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handler = handler
    }
}

// MARK: - Rectangles in video pixel space

enum VideoRectHandle: Int, CaseIterable, Identifiable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var id: Int { rawValue }
    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

    func point(in rect: CGRect) -> CGPoint {
        let x = movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX
        let y = movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY
        return CGPoint(x: x, y: y)
    }

    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch self {
            case .topLeft: position = .topLeft
            case .top: position = .top
            case .topRight: position = .topRight
            case .right: position = .right
            case .bottomRight: position = .bottomRight
            case .bottom: position = .bottom
            case .bottomLeft: position = .bottomLeft
            case .left: position = .left
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        if isCorner { return .crosshair }
        return movesLeft || movesRight ? .resizeLeftRight : .resizeUpDown
    }
}

enum VideoRectMath {
    /// `rect` moved by `delta`, kept inside `bounds`.
    static func moved(_ rect: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
        var result = rect.offsetBy(dx: delta.width, dy: delta.height)
        result.origin.x = max(bounds.minX, min(bounds.maxX - result.width, result.origin.x))
        result.origin.y = max(bounds.minY, min(bounds.maxY - result.height, result.origin.y))
        return result
    }

    /// `rect` with one handle dragged by `delta`, inside `bounds`, optionally keeping `ratio` (width / height).
    static func resized(_ rect: CGRect, handle: VideoRectHandle, by delta: CGSize, within bounds: CGRect,
                        ratio: CGFloat?, minimumSize: CGFloat) -> CGRect {
        let minimum = min(minimumSize, bounds.width, bounds.height)
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if handle.movesLeft { minX = min(max(bounds.minX, rect.minX + delta.width), maxX - minimum) }
        if handle.movesRight { maxX = max(min(bounds.maxX, rect.maxX + delta.width), minX + minimum) }
        if handle.movesTop { minY = min(max(bounds.minY, rect.minY + delta.height), maxY - minimum) }
        if handle.movesBottom { maxY = max(min(bounds.maxY, rect.maxY + delta.height), minY + minimum) }
        guard let ratio, ratio > 0 else {
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        var width = maxX - minX
        var height = maxY - minY
        let horizontal = handle.movesLeft || handle.movesRight
        let vertical = handle.movesTop || handle.movesBottom
        if horizontal && vertical {
            if width / ratio > height { height = width / ratio } else { width = height * ratio }
        } else if horizontal {
            height = width / ratio
        } else {
            width = height * ratio
        }
        // The opposite edge stays put; an untouched axis stays centered.
        let anchorX = handle.movesLeft ? rect.maxX : handle.movesRight ? rect.minX : rect.midX
        let anchorY = handle.movesTop ? rect.maxY : handle.movesBottom ? rect.minY : rect.midY
        let roomX = handle.movesLeft ? anchorX - bounds.minX
            : handle.movesRight ? bounds.maxX - anchorX
            : 2 * min(anchorX - bounds.minX, bounds.maxX - anchorX)
        let roomY = handle.movesTop ? anchorY - bounds.minY
            : handle.movesBottom ? bounds.maxY - anchorY
            : 2 * min(anchorY - bounds.minY, bounds.maxY - anchorY)
        let shrink = min(1, roomX / max(width, 0.001), roomY / max(height, 0.001))
        width *= shrink
        height *= shrink
        if width < minimum || height < minimum {
            let grow = max(minimum / max(width, 0.001), minimum / max(height, 0.001))
            if width * grow <= roomX + 0.5, height * grow <= roomY + 0.5 {
                width *= grow
                height *= grow
            }
        }
        let x = handle.movesLeft ? anchorX - width : handle.movesRight ? anchorX : anchorX - width / 2
        let y = handle.movesTop ? anchorY - height : handle.movesBottom ? anchorY : anchorY - height / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The rectangle spanned by a drag from `a` to `b`, optionally with `ratio`, inside `bounds`.
    static func spanning(_ a: CGPoint, _ b: CGPoint, within bounds: CGRect, ratio: CGFloat?) -> CGRect {
        let start = CGPoint(x: max(bounds.minX, min(bounds.maxX, a.x)), y: max(bounds.minY, min(bounds.maxY, a.y)))
        let end = CGPoint(x: max(bounds.minX, min(bounds.maxX, b.x)), y: max(bounds.minY, min(bounds.maxY, b.y)))
        var width = abs(end.x - start.x)
        var height = abs(end.y - start.y)
        let directionX: CGFloat = end.x >= start.x ? 1 : -1
        let directionY: CGFloat = end.y >= start.y ? 1 : -1
        if let ratio, ratio > 0 {
            if width / ratio > height { height = width / ratio } else { width = height * ratio }
            let roomX = directionX > 0 ? bounds.maxX - start.x : start.x - bounds.minX
            let roomY = directionY > 0 ? bounds.maxY - start.y : start.y - bounds.minY
            let shrink = min(1, roomX / max(width, 0.001), roomY / max(height, 0.001))
            width *= shrink
            height *= shrink
        }
        let x = directionX > 0 ? start.x : start.x - width
        let y = directionY > 0 ? start.y : start.y - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The largest rectangle with `ratio` inside `bounds`, centered on `center` as far as it fits.
    static func largest(ratio: CGFloat, in bounds: CGRect, centeredOn center: CGPoint? = nil) -> CGRect {
        guard ratio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let width: CGFloat
        let height: CGFloat
        if bounds.width / bounds.height > ratio {
            height = bounds.height
            width = height * ratio
        } else {
            width = bounds.width
            height = width / ratio
        }
        let middle = center ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let rect = CGRect(x: middle.x - width / 2, y: middle.y - height / 2, width: width, height: height)
        return moved(rect, by: .zero, within: bounds)
    }
}

/// Converts between video pixels and the view's points.
struct VideoPixelMapping {
    var frameSize: CGSize
    var videoRect: CGRect

    var scale: CGFloat { videoRect.width / max(frameSize.width, 1) }
    var bounds: CGRect { CGRect(origin: .zero, size: frameSize) }

    func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(x: videoRect.minX + rect.minX * scale, y: videoRect.minY + rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    func pixels(_ size: CGSize) -> CGSize {
        CGSize(width: size.width / max(scale, 0.0001), height: size.height / max(scale, 0.0001))
    }

    /// A point in the video rect's local coordinates, in pixels.
    func pixelPoint(local point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / max(scale, 0.0001), y: point.y / max(scale, 0.0001))
    }
}

/// An invisible layer over the video that draws a new rectangle on drag.
struct VideoRectDrawLayer: View {
    var mapping: VideoPixelMapping
    var ratio: CGFloat?
    var onDraw: (CGRect) -> Void
    var onEnd: () -> Void = {}
    var onTap: () -> Void = {}

    var body: some View {
        Color.white.opacity(0.001)
            .frame(width: max(1, mapping.videoRect.width), height: max(1, mapping.videoRect.height))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { value in
                    let a = mapping.pixelPoint(local: value.startLocation)
                    let b = mapping.pixelPoint(local: value.location)
                    onDraw(VideoRectMath.spanning(a, b, within: mapping.bounds, ratio: ratio))
                }
                .onEnded { _ in onEnd() })
            .simultaneousGesture(TapGesture().onEnded { onTap() })
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            .position(x: mapping.videoRect.midX, y: mapping.videoRect.midY)
    }
}

/// Border, optional thirds grid, eight handles, drag-to-move and drag-to-resize
/// for a rectangle in video pixel space.
struct VideoRectEditor: View {
    var rect: CGRect
    var mapping: VideoPixelMapping
    var ratio: CGFloat?
    var minimumSize: CGFloat = 16
    var tint: Color = .white
    var showsGrid = false
    var accessibilityText: String
    var onChange: (CGRect) -> Void
    var onBegin: () -> Void = {}

    @State private var origin: CGRect?

    var body: some View {
        let frame = mapping.viewRect(rect)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(grid(in: frame.size))
                .overlay(Rectangle().strokeBorder(tint, lineWidth: 1.5).shadow(color: .black.opacity(0.5), radius: 1))
                .frame(width: max(1, frame.width), height: max(1, frame.height))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = origin ?? rect
                        if origin == nil { origin = rect; onBegin() }
                        onChange(VideoRectMath.moved(start, by: mapping.pixels(value.translation), within: mapping.bounds))
                    }
                    .onEnded { _ in origin = nil })
                .onHover { inside in
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .accessibilityElement()
                .accessibilityLabel(accessibilityText)
                .position(x: frame.midX, y: frame.midY)
            ForEach(VideoRectHandle.allCases) { handle in
                handleView(handle)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let start = origin ?? rect
                            if origin == nil { origin = rect; onBegin() }
                            onChange(VideoRectMath.resized(start, handle: handle, by: mapping.pixels(value.translation),
                                                           within: mapping.bounds, ratio: ratio, minimumSize: minimumSize))
                        }
                        .onEnded { _ in origin = nil })
                    .onHover { inside in
                        if inside { handle.cursor.push() } else { NSCursor.pop() }
                    }
                    .position(handle.point(in: frame))
            }
        }
    }

    @ViewBuilder
    private func grid(in size: CGSize) -> some View {
        if showsGrid {
            Path { path in
                for index in 1...2 {
                    let x = size.width * CGFloat(index) / 3
                    let y = size.height * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.75)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func handleView(_ handle: VideoRectHandle) -> some View {
        if handle.isCorner {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(tint == .white ? Color.black.opacity(0.25) : tint, lineWidth: 1))
                .frame(width: 10, height: 10)
                .shadow(color: .black.opacity(0.45), radius: 1.5)
        } else {
            Capsule()
                .fill(Color.white)
                .frame(width: handle.movesLeft || handle.movesRight ? 5 : 18,
                       height: handle.movesLeft || handle.movesRight ? 18 : 5)
                .shadow(color: .black.opacity(0.45), radius: 1.5)
        }
    }
}

// MARK: - Small controls

/// Capsule chip for presets; orange when selected.
struct VideoChipStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: selected ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(selected ? Brand.buttonOrange : Color.primary.opacity(configuration.isPressed ? 0.15 : 0.07)))
            .contentShape(Capsule())
    }
}

/// Compact icon + label button with a faint plate, for secondary actions.
struct VideoActionStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Brand.buttonOrange : Color.primary.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill((prominent ? Brand.buttonOrange : Color.primary).opacity(configuration.isPressed ? 0.2 : (prominent ? 0.12 : 0.07))))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// A secondary caption under controls. Warnings are tinted orange.
struct VideoHint: View {
    var text: String
    var warning = false

    init(_ text: String, warning: Bool = false) {
        self.text = text
        self.warning = warning
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(warning ? AnyShapeStyle(Brand.buttonOrange) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Loads the player and timeline thumbnails for an editor.
@MainActor
enum VideoEditorLoader {
    static func load(_ player: MediaPlayerModel, url: URL, thumbnailCount: Int = 12) async -> [CGImage] {
        if player.duration <= 0 && player.isLoading {
            await player.load(url)
        }
        return await VideoFrames.thumbnails(source: url, playable: player.playableURL, duration: player.duration,
                                            count: thumbnailCount, height: 90)
    }
}
