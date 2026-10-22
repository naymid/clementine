import AppKit
import AVFoundation
import SwiftUI

// MARK: - Preview sources

/// AVFoundation cannot play MKV, WebM, AVI, WMV, OGG, Opus or WMA. For those,
/// a small proxy is transcoded once so editors can preview them. Times are
/// identical, so ranges picked on the proxy apply to the original.
enum PreviewSource {
    private static var cache: [String: URL] = [:]
    private static let lock = NSLock()

    static func playableURL(for url: URL, info: MediaInfo) async -> URL? {
        if await isPlayable(url) { return url }
        let key = url.path + "|" + String(describing: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
        let cached = lock.withLock { cache[key] }
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return cached }
        guard let ffmpeg = ToolPaths.ffmpeg else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clementine-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(UUID().uuidString + (info.hasVideo ? ".mp4" : ".m4a"))
        var arguments = ["-y", "-v", "error", "-i", url.path]
        if info.hasVideo {
            arguments += ["-vf", "scale=-2:'min(540,ih)'", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "26", "-pix_fmt", "yuv420p"]
        } else {
            arguments += ["-vn"]
        }
        arguments += info.hasAudio ? ["-c:a", "aac", "-b:a", "160k"] : ["-an"]
        arguments += [output.path]
        do {
            try await ProcessRunner().run(ffmpeg, arguments)
        } catch {
            return nil
        }
        lock.withLock { cache[key] = output }
        return output
    }

    static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let playable = try? await asset.load(.isPlayable), playable else { return false }
        let tracks = (try? await asset.load(.tracks)) ?? []
        return !tracks.isEmpty
    }
}

// MARK: - Player

/// AVPlayer wrapper with published time, play/pause and optional range looping.
@MainActor
final class MediaPlayerModel: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = true
    @Published private(set) var info = MediaInfo()
    @Published var unavailableMessage: String?

    let player = AVPlayer()
    private(set) var playableURL: URL?
    /// When set, playback starts at the lower bound and stops at the upper bound.
    var playRange: ClosedRange<Double>?
    var rate: Float = 1 {
        didSet { if isPlaying { player.rate = rate } }
    }
    private var timeObserver: Any?
    private var closeObserver: NSObjectProtocol?

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        closeObserver = NotificationCenter.default.addObserver(forName: .toolWindowWillClose, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    /// Probes and prepares the file. Safe to call once per editor.
    func load(_ url: URL) async {
        isLoading = true
        let info = (try? await MediaInfo.probe(url)) ?? MediaInfo()
        self.info = info
        duration = info.duration
        if let playable = await PreviewSource.playableURL(for: url, info: info) {
            playableURL = playable
            player.replaceCurrentItem(with: AVPlayerItem(url: playable))
            if duration <= 0, let seconds = try? await AVURLAsset(url: playable).load(.duration).seconds, seconds.isFinite {
                duration = seconds
            }
        } else {
            unavailableMessage = info.hasVideo
                ? "Playback is unavailable for this video. You can still scrub the timeline and export."
                : "Audio preview is unavailable for this file. You can still export the selected range."
        }
        isLoading = false
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if let range = playRange, isPlaying, seconds >= range.upperBound {
            pause()
            seek(to: range.upperBound)
        }
        if isPlaying, player.rate == 0 { isPlaying = false }
    }

    func play() {
        guard player.currentItem != nil else { return }
        if let range = playRange, currentTime < range.lowerBound || currentTime >= range.upperBound - 0.02 {
            seek(to: range.lowerBound)
        } else if playRange == nil, duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double, precise: Bool = true) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        currentTime = clamped
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }
}

/// Shows an AVPlayer's video, aspect-fit, with no controls.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    final class PlayerView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.addSublayer(playerLayer)
            playerLayer.videoGravity = .resizeAspect
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.playerLayer.player = player
    }
}

/// Play/pause button plus "current / total" time readout. Space toggles playback.
struct PlaybackBar<Trailing: View>: View {
    @ObservedObject var player: MediaPlayerModel
    var showsFraction = true
    @ViewBuilder var trailing: () -> Trailing

    init(player: MediaPlayerModel, showsFraction: Bool = true, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.player = player
        self.showsFraction = showsFraction
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pause preview (Space)" : "Play preview (Space)")
            .disabled(player.playableURL == nil)
            Text("\(FileNaming.formatTime(player.currentTime, showsFraction: showsFraction)) / \(FileNaming.formatTime(player.duration, showsFraction: showsFraction))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension PlaybackBar where Trailing == EmptyView {
    init(player: MediaPlayerModel, showsFraction: Bool = true) {
        self.init(player: player, showsFraction: showsFraction) { EmptyView() }
    }
}

// MARK: - Thumbnails

enum ThumbnailLoader {
    /// Evenly spaced frames across the video, from the playable (or proxy) URL.
    static func thumbnails(for url: URL, count: Int, maxHeight: CGFloat = 120) async -> [CGImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0, count > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxHeight * 3, height: maxHeight)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var images: [CGImage] = []
        for index in 0..<count {
            let seconds = duration * (Double(index) + 0.5) / Double(count)
            if let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image {
                images.append(image)
            }
        }
        return images
    }

    /// One frame at an exact time.
    static func frame(for url: URL, at seconds: Double, maxSize: CGSize = CGSize(width: 1920, height: 1920)) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}

/// A row of video thumbnails filling its width.
struct ThumbnailStrip: View {
    var images: [CGImage]

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width / CGFloat(max(images.count, 1)), height: proxy.size.height)
                        .clipped()
                }
            }
        }
        .background(Color.black.opacity(0.4))
    }
}

// MARK: - Waveforms

enum WaveformLoader {
    /// Peak amplitude per bucket (0...1) for each channel. Decodes with ffmpeg,
    /// so it works for every audio format Clementine supports.
    static func channels(for url: URL, buckets: Int, channelCount: Int = 1) async throws -> [[Float]] {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw ProcessError.missingTool("ffmpeg") }
        let result = try await ProcessRunner().run(ffmpeg, [
            "-v", "error", "-i", url.path, "-vn", "-ac", "\(channelCount)", "-ar", "8000", "-f", "f32le", "-",
        ])
        let data = result.stdout
        let sampleCount = data.count / 4 / channelCount
        guard sampleCount > 0 else { return Array(repeating: Array(repeating: 0, count: buckets), count: channelCount) }
        var output = Array(repeating: Array(repeating: Float(0), count: buckets), count: channelCount)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Float.self)
            let perBucket = max(1, sampleCount / buckets)
            for bucket in 0..<buckets {
                let start = bucket * sampleCount / buckets
                let end = min(sampleCount, start + perBucket)
                for channel in 0..<channelCount {
                    var peak: Float = 0
                    var index = start
                    while index < end {
                        peak = max(peak, abs(samples[index * channelCount + channel]))
                        index += 1
                    }
                    output[channel][bucket] = peak
                }
            }
        }
        let maximum = max(output.flatMap { $0 }.max() ?? 1, 0.0001)
        return output.map { $0.map { min(1, $0 / maximum) } }
    }

    static func samples(for url: URL, buckets: Int) async throws -> [Float] {
        try await channels(for: url, buckets: buckets, channelCount: 1).first ?? []
    }
}

/// Mirrored bar waveform.
struct WaveformView: View {
    var samples: [Float]
    var color: Color = Color.primary.opacity(0.55)

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let barWidth = size.width / CGFloat(samples.count)
            let mid = size.height / 2
            var path = Path()
            for (index, sample) in samples.enumerated() {
                let height = max(1, CGFloat(sample) * size.height * 0.92)
                let rect = CGRect(x: CGFloat(index) * barWidth, y: mid - height / 2, width: max(1, barWidth * 0.7), height: height)
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 0.5, height: 0.5))
            }
            context.fill(path, with: .color(color))
        }
    }
}

// MARK: - Range track

/// A timeline with a draggable selection (orange frame with grips), a playhead,
/// and click-to-scrub. Used for trimming video and audio and for time ranges.
struct RangeTrack<Background: View>: View {
    @Binding var start: Double
    @Binding var end: Double
    var duration: Double
    var playhead: Double?
    var minimumLength: Double = 0.1
    var onScrub: (Double) -> Void = { _ in }
    var onEditingChanged: (Bool) -> Void = { _ in }
    @ViewBuilder var background: () -> Background

    @State private var dragOrigin: (start: Double, end: Double)?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let handle: CGFloat = 12
            let usable = max(1, width - handle * 2)
            let x = { (time: Double) -> CGFloat in handle + CGFloat(time / max(duration, 0.001)) * usable }
            let time = { (position: CGFloat) -> Double in Double((position - handle) / usable) * duration }
            ZStack(alignment: .topLeading) {
                // Hit areas must be set before .offset, which moves drawing but not the layout frame.
                background()
                    .frame(width: usable, height: proxy.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        onScrub(max(0, min(duration, time(value.location.x + handle))))
                    })
                    .offset(x: handle)
                // Dim the parts outside the selection.
                Rectangle().fill(Color.black.opacity(0.45))
                    .frame(width: max(0, x(start) - handle), height: proxy.size.height)
                    .offset(x: handle)
                    .allowsHitTesting(false)
                Rectangle().fill(Color.black.opacity(0.45))
                    .frame(width: max(0, x(duration) - x(end)), height: proxy.size.height)
                    .offset(x: x(end))
                    .allowsHitTesting(false)
                // Selection frame.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Brand.buttonOrange, lineWidth: 3)
                    .frame(width: max(handle * 2, x(end) - x(start) + handle * 2), height: proxy.size.height)
                    .offset(x: x(start) - handle)
                    .allowsHitTesting(false)
                grip(width: handle, height: proxy.size.height, edge: .leading)
                    .gesture(DragGesture(coordinateSpace: .named("track")).onChanged { value in
                        onEditingChanged(true)
                        start = max(0, min(end - minimumLength, time(value.location.x + handle / 2)))
                        onScrub(start)
                    }.onEnded { _ in onEditingChanged(false) })
                    .offset(x: x(start) - handle)
                grip(width: handle, height: proxy.size.height, edge: .trailing)
                    .gesture(DragGesture(coordinateSpace: .named("track")).onChanged { value in
                        onEditingChanged(true)
                        end = min(duration, max(start + minimumLength, time(value.location.x - handle / 2)))
                        onScrub(end)
                    }.onEnded { _ in onEditingChanged(false) })
                    .offset(x: x(end))
                if let playhead {
                    Capsule()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
                        .frame(width: 3, height: proxy.size.height + 8)
                        .offset(x: x(playhead) - 1.5, y: -4)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
            .coordinateSpace(name: "track")
        }
    }

    private func grip(width: CGFloat, height: CGFloat, edge: HorizontalEdge) -> some View {
        UnevenRoundedRectangle(cornerRadii: edge == .leading
                               ? .init(topLeading: 6, bottomLeading: 6)
                               : .init(bottomTrailing: 6, topTrailing: 6), style: .continuous)
            .fill(Brand.buttonOrange)
            .overlay(Capsule().fill(Color.white.opacity(0.9)).frame(width: 2.5, height: height * 0.36))
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

/// Seconds entry field, e.g. "12.50".
struct SecondsField: View {
    var title: String
    @Binding var seconds: Double
    var range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { seconds }, set: { seconds = min(range.upperBound, max(range.lowerBound, $0)) }),
                      format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .accessibilityLabel("\(title) in seconds")
        }
    }
}

// MARK: - ffmpeg helpers for tools

enum FFmpegTool {
    /// Runs ffmpeg with progress mapped from "time=" against `duration`.
    static func run(_ arguments: [String], duration: Double, context: JobContext) async throws {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw ProcessError.missingTool("ffmpeg") }
        try await MediaConverter.run(ffmpeg, ["-y", "-hide_banner", "-nostdin"] + arguments, duration: duration, context: context)
    }

    /// Video encoder arguments matching the output container.
    static func videoCodecArguments(for url: URL, crf: Int = 20) -> [String] {
        switch url.pathExtension.lowercased() {
        case "webm": return ["-c:v", "libvpx-vp9", "-crf", "\(crf + 10)", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
        case "avi": return ["-c:v", "mpeg4", "-vtag", "xvid", "-q:v", "3"]
        case "wmv": return ["-c:v", "wmv2", "-q:v", "3"]
        default: return ["-c:v", "libx264", "-preset", "medium", "-crf", "\(crf)", "-pix_fmt", "yuv420p"]
        }
    }

    /// Audio encoder arguments matching the output container.
    static func audioCodecArguments(for url: URL) -> [String] {
        switch url.pathExtension.lowercased() {
        case "webm", "opus": return ["-c:a", "libopus", "-b:a", "160k"]
        case "ogg": return ["-c:a", "libvorbis", "-b:a", "192k"]
        case "avi", "mp3": return ["-c:a", "libmp3lame", "-b:a", "192k"]
        case "wmv", "wma": return ["-c:a", "wmav2", "-b:a", "192k"]
        case "wav": return ["-c:a", "pcm_s16le"]
        case "aiff", "aif": return ["-c:a", "pcm_s16be"]
        case "flac": return ["-c:a", "flac"]
        default: return ["-c:a", "aac", "-b:a", "192k"]
        }
    }
}
