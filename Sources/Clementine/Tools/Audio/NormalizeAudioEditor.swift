import AppKit
import SwiftUI

// MARK: - Processing

struct LoudnessTarget: Equatable {
    /// Integrated loudness in LUFS.
    var integrated: Double = -16
    /// Loudness range in LU.
    var range: Double = 11
    /// True peak ceiling in dBTP.
    var truePeak: Double = -1.5
}

/// loudnorm's first-pass measurement of a file.
struct LoudnessMeasurement: Equatable {
    var integrated: Double
    var truePeak: Double
    var range: Double
    var threshold: Double
    var targetOffset: Double
    /// The targets the measurement pass ran with (only `targetOffset` depends on them).
    var target: LoudnessTarget
}

enum NormalizeAudioProcessor {
    /// Two-pass EBU R128 normalization: measure, then apply a linear gain with the measured values.
    static func normalize(_ url: URL, target: LoudnessTarget, context: JobContext) async throws -> URL {
        let info = try await AudioStreamInfo.probe(url)
        let log = try await AudioFFmpeg.run(["-i", url.path, "-vn", "-af", measureFilter(target), "-f", "null", "-"],
                                            duration: info.duration, context: context, progress: 0...0.45)
        let measured = try parse(log, target: target)
        let output = FileNaming.output(beside: url, suffix: "-normalized", extension: url.pathExtension)
        try await AudioOutput.encode(output: output, source: info, duration: info.duration, context: context, progress: 0.45...1) { mapping in
            ["-i", url.path] + mapping + ["-af", applyFilter(target: target, measured: measured)]
                + AudioOutput.codecArguments(for: output, source: info)
        }
        return output
    }

    /// Measures integrated loudness, true peak and loudness range (first pass only).
    static func measure(_ url: URL, target: LoudnessTarget, runner: ProcessRunner) async throws -> LoudnessMeasurement {
        let log = try await AudioFFmpeg.run(["-i", url.path, "-vn", "-af", measureFilter(target), "-f", "null", "-"], runner: runner)
        return try parse(log, target: target)
    }

    /// Renders `length` seconds from `start` with the second-pass filter into a temporary M4A.
    static func renderPreview(_ url: URL, target: LoudnessTarget, measured: LoudnessMeasurement,
                              start: Double, length: Double, runner: ProcessRunner) async throws -> URL {
        let output = AudioScratch.file("m4a")
        do {
            try await AudioFFmpeg.run([
                "-ss", AudioFFmpeg.number(start), "-t", AudioFFmpeg.number(length), "-i", url.path, "-vn",
                "-af", applyFilter(target: target, measured: measured),
                "-c:a", "aac", "-b:a", "192k", "-ar", "48000", output.path,
            ], runner: runner)
        } catch {
            AudioScratch.remove(output)
            throw error
        }
        return output
    }

    /// Where a short preview excerpt sits: the whole file when short, otherwise a stretch a fifth of the way in.
    static func previewWindow(duration: Double, length: Double = 15) -> (start: Double, length: Double) {
        let clip = min(length, max(0, duration))
        let start = duration > length + 5 ? min(duration * 0.2, duration - clip) : 0
        return (start, clip)
    }

    static func measureFilter(_ target: LoudnessTarget) -> String {
        "loudnorm=I=\(AudioFFmpeg.number(target.integrated, digits: 1)):LRA=\(AudioFFmpeg.number(target.range, digits: 1)):TP=\(AudioFFmpeg.number(target.truePeak, digits: 1)):print_format=json"
    }

    static func applyFilter(target: LoudnessTarget, measured: LoudnessMeasurement) -> String {
        func clamp(_ value: Double, _ range: ClosedRange<Double>) -> String {
            AudioFFmpeg.number(min(range.upperBound, max(range.lowerBound, value)), digits: 2)
        }
        // The first pass's offset only matches the targets it was measured with.
        let offset = measured.target == target ? measured.targetOffset : 0
        return [
            "loudnorm=I=\(AudioFFmpeg.number(target.integrated, digits: 1))",
            "LRA=\(AudioFFmpeg.number(target.range, digits: 1))",
            "TP=\(AudioFFmpeg.number(target.truePeak, digits: 1))",
            "measured_I=\(clamp(measured.integrated, -99...0))",
            "measured_LRA=\(clamp(measured.range, 0...99))",
            "measured_TP=\(clamp(measured.truePeak, -99...99))",
            "measured_thresh=\(clamp(measured.threshold, -99...0))",
            "offset=\(clamp(offset, -99...99))",
            "linear=true",
            "print_format=summary",
        ].joined(separator: ":")
    }

    /// Reads the JSON block loudnorm prints at the end of the first pass.
    static func parse(_ log: String, target: LoudnessTarget) throws -> LoudnessMeasurement {
        guard let open = log.range(of: "{", options: .backwards),
              let close = log.range(of: "}", options: .backwards), open.lowerBound < close.upperBound,
              let json = try? JSONSerialization.jsonObject(with: Data(log[open.lowerBound..<close.upperBound].utf8)) as? [String: Any]
        else { throw ProcessError.failed("The loudness of this audio could not be measured.") }
        func value(_ key: String) -> Double {
            guard let text = json[key] as? String else { return .nan }
            return Double(text.trimmingCharacters(in: .whitespaces)) ?? .nan
        }
        let measurement = LoudnessMeasurement(integrated: value("input_i"), truePeak: value("input_tp"), range: value("input_lra"),
                                              threshold: value("input_thresh"), targetOffset: value("target_offset"), target: target)
        guard measurement.integrated.isFinite, measurement.integrated > -70 else {
            throw ProcessError.failed("This audio is silent, so there is nothing to normalize.")
        }
        var safe = measurement
        if !safe.truePeak.isFinite { safe.truePeak = -99 }
        if !safe.range.isFinite { safe.range = 0 }
        if !safe.threshold.isFinite { safe.threshold = -70 }
        if !safe.targetOffset.isFinite { safe.targetOffset = 0 }
        return safe
    }
}

enum LoudnessPreset: String, CaseIterable, Identifiable {
    case podcast, streaming, broadcast, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .podcast: return "Podcast"
        case .streaming: return "Streaming"
        case .broadcast: return "Broadcast"
        case .custom: return "Custom"
        }
    }

    /// Integrated loudness and true peak for the preset.
    var values: (integrated: Double, truePeak: Double)? {
        switch self {
        case .podcast: return (-16, -1.5)
        case .streaming: return (-14, -1.0)
        case .broadcast: return (-23, -1.0)
        case .custom: return nil
        }
    }

    static func matching(_ target: LoudnessTarget) -> LoudnessPreset {
        allCases.first { preset in
            guard let values = preset.values else { return false }
            return abs(values.integrated - target.integrated) < 0.05 && abs(values.truePeak - target.truePeak) < 0.05
        } ?? .custom
    }
}

// MARK: - Model

@MainActor
final class NormalizeAudioModel: ObservableObject {
    enum Side: Hashable { case original, normalized }

    let url: URL
    let original = MediaPlayerModel()
    let normalized = MediaPlayerModel()

    @Published var target = LoudnessTarget() {
        didSet { if target != oldValue { renderPreview(after: 0.45) } }
    }
    @Published private(set) var measurement: LoudnessMeasurement?
    @Published private(set) var isMeasuring = true
    @Published private(set) var measureError: String?
    @Published private(set) var isRenderingPreview = false
    @Published private(set) var previewFailed = false
    @Published private(set) var side: Side = .normalized
    @Published private(set) var excerpt: (start: Double, length: Double) = (0, 0)

    private var previewURL: URL?
    private var loaded = false
    private let measureJob = AudioEditorJob()
    private let previewJob = AudioEditorJob()

    init(url: URL) {
        self.url = url
    }

    deinit {
        if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
    }

    var preset: LoudnessPreset {
        get { LoudnessPreset.matching(target) }
        set {
            guard let values = newValue.values else { return }
            target.integrated = values.integrated
            target.truePeak = values.truePeak
        }
    }

    var activePlayer: MediaPlayerModel { side == .original ? original : normalized }

    /// Seconds into the excerpt for the active player.
    var position: Double {
        side == .original ? max(0, original.currentTime - excerpt.start) : normalized.currentTime
    }

    var canPlay: Bool {
        side == .original ? original.playableURL != nil : (previewURL != nil && !previewFailed)
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        await original.load(url)
        var duration = original.duration
        if duration <= 0 { duration = (try? await AudioStreamInfo.probe(url).duration) ?? 0 }
        excerpt = NormalizeAudioProcessor.previewWindow(duration: duration)
        original.playRange = excerpt.start...(excerpt.start + excerpt.length)
        original.seek(to: excerpt.start)
        measure()
    }

    private func measure() {
        isMeasuring = true
        measureError = nil
        let target = self.target
        let url = self.url
        measureJob.start { [weak self] runner in
            do {
                let measurement = try await NormalizeAudioProcessor.measure(url, target: target, runner: runner)
                guard let self, !runner.isCancelled else { return }
                self.measurement = measurement
                self.isMeasuring = false
                self.renderPreview()
            } catch {
                guard let self, !runner.isCancelled else { return }
                self.isMeasuring = false
                self.measureError = (error as? LocalizedError)?.errorDescription ?? "The loudness of this audio could not be measured."
                self.previewFailed = true
            }
        }
    }

    func renderPreview(after delay: Double = 0) {
        guard let measurement else { return }
        isRenderingPreview = true
        previewFailed = false
        let target = self.target
        let excerpt = self.excerpt
        let url = self.url
        previewJob.start(after: delay) { [weak self] runner in
            do {
                let rendered = try await NormalizeAudioProcessor.renderPreview(url, target: target, measured: measurement,
                                                                               start: excerpt.start, length: excerpt.length, runner: runner)
                guard let self, !runner.isCancelled else {
                    AudioScratch.remove(rendered)
                    return
                }
                let wasPlaying = self.side == .normalized && self.normalized.isPlaying
                let position = self.normalized.currentTime
                self.normalized.pause()
                self.normalized.unavailableMessage = nil
                await self.normalized.load(rendered)
                AudioScratch.remove(self.previewURL)
                self.previewURL = rendered
                self.isRenderingPreview = false
                if self.normalized.playableURL == nil {
                    self.previewFailed = true
                    return
                }
                self.normalized.seek(to: min(position, max(0, self.normalized.duration - 0.05)))
                if wasPlaying { self.normalized.play() }
            } catch {
                guard let self, !runner.isCancelled else { return }
                self.isRenderingPreview = false
                self.previewFailed = true
            }
        }
    }

    func togglePlayback() {
        let player = activePlayer
        if player.isPlaying {
            player.pause()
        } else if canPlay {
            if side == .original { original.playRange = excerpt.start...(excerpt.start + excerpt.length) }
            player.play()
        }
    }

    func select(_ newSide: Side) {
        guard newSide != side else { return }
        let wasPlaying = activePlayer.isPlaying
        let position = self.position
        activePlayer.pause()
        side = newSide
        seek(to: position)
        if wasPlaying, canPlay { activePlayer.play() }
    }

    /// Seeks both players to `seconds` into the excerpt.
    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, excerpt.length))
        original.seek(to: excerpt.start + clamped)
        if previewURL != nil { normalized.seek(to: clamped) }
    }

    func stopPlayback() {
        original.pause()
        normalized.pause()
    }
}

// MARK: - Editor

struct NormalizeAudioEditor: View {
    @ObservedObject var session: ToolSession
    @StateObject private var model: NormalizeAudioModel

    init(session: ToolSession) {
        self.session = session
        _model = StateObject(wrappedValue: NormalizeAudioModel(url: session.primaryURL))
    }

    var body: some View {
        ToolScaffold(session: session) {
            VStack(alignment: .leading, spacing: 14) {
                currentLoudness
                targetSection
                ToolSection("Preview") {
                    NormalizePreviewBar(model: model, original: model.original, normalized: model.normalized)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxHeight: .infinity, alignment: .top)
        } footer: {
            ToolFooter(session: session, primaryTitle: "Normalize Volume", primaryEnabled: true) {
                let target = model.target
                model.stopPlayback()
                session.runPerItem { url, context in
                    [try await NormalizeAudioProcessor.normalize(url, target: target, context: context)]
                }
            } leading: {
                if session.urls.count > 1 {
                    AudioNote("Each file is normalized on its own.", symbol: "square.stack")
                }
            }
        }
        .task { await model.load() }
    }

    private var currentLoudness: some View {
        ToolSection(session.urls.count > 1 ? "Current loudness · \(session.primaryURL.lastPathComponent)" : "Current loudness") {
            HStack(alignment: .center, spacing: 12) {
                if let measurement = model.measurement {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(AudioFFmpeg.number(measurement.integrated, digits: 1))
                            .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        Text("LUFS")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("True peak \(AudioFFmpeg.number(measurement.truePeak, digits: 1)) dBTP")
                        Text("Loudness range \(AudioFFmpeg.number(measurement.range, digits: 1)) LU")
                    }
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                } else if model.isMeasuring {
                    AudioProgressNote(text: "Measuring loudness")
                        .frame(height: 30)
                    Spacer()
                } else {
                    AudioNote(model.measureError ?? "The loudness of this audio could not be measured.",
                              symbol: "exclamationmark.triangle.fill", tint: .orange)
                        .frame(minHeight: 30)
                    Spacer()
                }
            }
            if let measurement = model.measurement {
                let change = model.target.integrated - measurement.integrated
                AudioNote("\(change >= 0 ? "+" : "")\(AudioFFmpeg.number(change, digits: 1)) dB to reach \(AudioFFmpeg.number(model.target.integrated, digits: 1)) LUFS",
                          symbol: change >= 0 ? "arrow.up.right" : "arrow.down.right")
            }
        }
    }

    private var targetSection: some View {
        ToolSection("Target") {
            ToolSettingRow("Preset") {
                ToolSegmented(selection: Binding(get: { model.preset }, set: { model.preset = $0 }),
                              options: LoudnessPreset.allCases.map { ($0, $0.title) })
            }
            AudioValueSlider(title: "Target loudness", value: $model.target.integrated, range: -30 ... -5, step: 0.5,
                             format: { "\(AudioFFmpeg.number($0, digits: 1)) LUFS" })
            AudioValueSlider(title: "Loudness range", value: $model.target.range, range: 1...50, step: 1,
                             format: { "\(Int($0.rounded())) LU" })
            AudioValueSlider(title: "True peak", value: $model.target.truePeak, range: -9...0, step: 0.1,
                             format: { "\(AudioFFmpeg.number($0, digits: 1)) dBTP" })
            AudioNote("-16 LUFS is a balanced default for spoken audio and music. The true peak limit helps prevent clipping after encoding.",
                      symbol: "info.circle")
        }
    }
}

/// Play button, excerpt progress and the Original / Normalized switch.
private struct NormalizePreviewBar: View {
    @ObservedObject var model: NormalizeAudioModel
    @ObservedObject var original: MediaPlayerModel
    @ObservedObject var normalized: MediaPlayerModel

    var body: some View {
        let active = model.side == .original ? original : normalized
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AudioRoundButton(symbol: active.isPlaying ? "pause.fill" : "play.fill",
                                 help: active.isPlaying ? "Pause preview (Space)" : "Play preview (Space)",
                                 isBusy: model.side == .normalized && model.isRenderingPreview && !active.isPlaying) {
                    model.togglePlayback()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!model.canPlay)
                Text("\(AudioText.time(model.position)) / \(AudioText.time(model.excerpt.length))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                ExcerptProgress(fraction: model.excerpt.length > 0 ? model.position / model.excerpt.length : 0) { fraction in
                    model.seek(to: fraction * model.excerpt.length)
                }
                .frame(height: 16)
                ToolSegmented(selection: Binding(get: { model.side }, set: { model.select($0) }),
                              options: [(NormalizeAudioModel.Side.original, "Original"), (.normalized, "Normalized")])
            }
            Group {
                if model.previewFailed && model.measurement != nil {
                    AudioNote("Normalized preview unavailable. You can still normalize this audio.",
                              symbol: "exclamationmark.triangle.fill", tint: .orange)
                } else if model.isRenderingPreview || model.isMeasuring {
                    AudioProgressNote(text: "Preparing a normalized preview")
                } else if model.measurement != nil {
                    AudioNote(model.excerpt.start > 0
                              ? "A \(Int(model.excerpt.length.rounded()))-second excerpt from \(AudioText.time(model.excerpt.start)). Switch to compare with the original."
                              : "Switch between Original and Normalized to compare.",
                              symbol: "headphones")
                }
            }
            .frame(minHeight: 16, alignment: .leading)
        }
    }
}

/// Thin clickable progress line.
private struct ExcerptProgress: View {
    var fraction: Double
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 4)
                Capsule().fill(Brand.buttonOrange).frame(width: CGFloat(min(1, max(0, fraction))) * width, height: 4)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onSeek(Double(min(width, max(0, value.location.x)) / width))
            })
        }
    }
}
