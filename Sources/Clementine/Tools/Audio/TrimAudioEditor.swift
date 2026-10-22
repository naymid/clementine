import AppKit
import SwiftUI

// MARK: - Processing

enum TrimAudioProcessor {
    struct ContentBounds: Equatable {
        var start: Double
        var end: Double
    }

    /// Saves `start...end` of `url` beside it as "<name>-trimmed.<ext>", in the same format.
    static func trim(_ url: URL, start: Double, end: Double, context: JobContext) async throws -> URL {
        let info = try await AudioStreamInfo.probe(url)
        let lower = max(0, start)
        let upper = info.duration > 0 ? min(info.duration, end) : end
        guard upper - lower >= 0.05 else { throw ProcessError.failed("The selected range is too short to save.") }
        let output = FileNaming.output(beside: url, suffix: "-trimmed", extension: url.pathExtension)
        let length = upper - lower
        try await AudioOutput.encode(output: output, source: info, duration: length, context: context) { mapping in
            ["-ss", AudioFFmpeg.number(lower), "-t", AudioFFmpeg.number(length), "-i", url.path]
                + mapping + AudioOutput.codecArguments(for: output, source: info)
        }
        return output
    }

    /// Where the sound starts and stops once leading and trailing silence quieter than
    /// `thresholdDB` is skipped. Nil when the whole file is silent at that threshold.
    static func contentBounds(_ url: URL, thresholdDB: Double, duration: Double, runner: ProcessRunner) async throws -> ContentBounds? {
        let log = try await AudioFFmpeg.run([
            "-i", url.path, "-vn", "-af", "silencedetect=noise=\(AudioFFmpeg.number(thresholdDB, digits: 1))dB:d=0.05", "-f", "null", "-",
        ], runner: runner)
        return contentBounds(fromSilenceLog: log, duration: duration)
    }

    /// Reads silencedetect's "silence_start: x" / "silence_end: y" lines.
    static func contentBounds(fromSilenceLog log: String, duration: Double) -> ContentBounds? {
        func value(after marker: String, in line: Substring) -> Double? {
            guard let range = line.range(of: marker) else { return nil }
            return Double(line[range.upperBound...].prefix { !$0.isWhitespace && $0 != "|" })
        }
        var intervals: [(start: Double, end: Double?)] = []
        for line in log.split(whereSeparator: \.isNewline) {
            if let start = value(after: "silence_start: ", in: line) {
                intervals.append((max(0, start), nil))
            } else if let end = value(after: "silence_end: ", in: line), !intervals.isEmpty, intervals[intervals.count - 1].end == nil {
                intervals[intervals.count - 1].end = end
            }
        }
        let tolerance = 0.02
        var start = 0.0
        var end = duration
        if let first = intervals.first, first.start <= tolerance {
            guard let firstEnd = first.end, firstEnd < duration - tolerance else { return nil }
            start = firstEnd
        }
        if let last = intervals.last, last.start > tolerance, last.end.map({ $0 >= duration - tolerance }) ?? true {
            end = last.start
        }
        // Keep a hair of the fade-in and fade-out.
        let padding = 0.02
        start = max(0, start - padding)
        end = min(duration, end + padding)
        guard end - start > 0.05 else { return nil }
        return ContentBounds(start: start, end: end)
    }
}

// MARK: - Model

@MainActor
final class TrimAudioModel: ObservableObject {
    let url: URL
    let player = MediaPlayerModel()

    @Published var samples: [Float] = []
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published private(set) var isLoaded = false
    @Published var autoTrim = false {
        didSet { if autoTrim != oldValue { autoTrimChanged() } }
    }
    @Published var threshold: Double = -45 {
        didSet { if autoTrim, threshold != oldValue { detectSilence(after: 0.3) } }
    }
    @Published private(set) var isDetecting = false
    @Published private(set) var isSilent = false
    @Published private(set) var detectionSummary: String?

    @Published private(set) var duration: Double = 0

    private let detection = AudioEditorJob()

    init(url: URL, autoTrim: Bool = false) {
        self.url = url
        self.autoTrim = autoTrim
    }

    var length: Double { max(0, end - start) }
    var canSave: Bool { isLoaded && length >= 0.05 && !(autoTrim && (isSilent || isDetecting)) }

    func load() async {
        guard !isLoaded else { return }
        async let waveform: [Float]? = try? await WaveformLoader.samples(for: url, buckets: 420)
        await player.load(url)
        duration = player.duration
        if duration <= 0, let info = try? await AudioStreamInfo.probe(url) {
            duration = info.duration
        }
        end = duration
        samples = await waveform ?? []
        isLoaded = true
        if autoTrim { detectSilence() }
    }

    func scrub(to seconds: Double) {
        player.playRange = nil
        player.seek(to: seconds, precise: false)
    }

    func playSelection() {
        guard length > 0 else { return }
        player.pause()
        player.playRange = start...end
        player.seek(to: start)
        player.play()
    }

    private func autoTrimChanged() {
        if autoTrim {
            detectSilence()
        } else {
            detection.cancel()
            isDetecting = false
            isSilent = false
            detectionSummary = nil
            start = 0
            end = duration
        }
    }

    func detectSilence(after delay: Double = 0) {
        guard isLoaded, duration > 0 else { return }
        isDetecting = true
        isSilent = false
        let threshold = self.threshold
        let duration = self.duration
        let url = self.url
        detection.start(after: delay) { [weak self] runner in
            let bounds: TrimAudioProcessor.ContentBounds?
            do {
                bounds = try await TrimAudioProcessor.contentBounds(url, thresholdDB: threshold, duration: duration, runner: runner)
            } catch {
                guard let self, !runner.isCancelled else { return }
                self.isDetecting = false
                self.detectionSummary = "Silence detection failed. You can still drag the ends to trim."
                return
            }
            guard let self, !runner.isCancelled else { return }
            self.isDetecting = false
            if let bounds {
                self.isSilent = false
                self.start = bounds.start
                self.end = bounds.end
                self.player.playRange = nil
                if self.player.currentTime < bounds.start || self.player.currentTime > bounds.end {
                    self.player.seek(to: bounds.start)
                }
                let leading = bounds.start
                let trailing = max(0, duration - bounds.end)
                if leading < 0.05 && trailing < 0.05 {
                    self.detectionSummary = "No silence found at the start or end."
                } else {
                    self.detectionSummary = "Skips \(AudioText.seconds(leading)) of silence at the start and \(AudioText.seconds(trailing)) at the end."
                }
            } else {
                self.isSilent = true
                self.detectionSummary = nil
            }
        }
    }
}

// MARK: - Editor

struct TrimAudioEditor: View {
    @ObservedObject var session: ToolSession
    @StateObject private var model: TrimAudioModel

    init(session: ToolSession, autoTrim: Bool = false) {
        self.session = session
        _model = StateObject(wrappedValue: TrimAudioModel(url: session.primaryURL, autoTrim: autoTrim))
    }

    var body: some View {
        ToolScaffold(session: session) {
            VStack(alignment: .leading, spacing: 14) {
                TrimAudioTimeline(model: model, player: model.player)
                ToolSection {
                    ToolSettingRow("Trim silent ends automatically") {
                        Toggle("Trim silent ends automatically", isOn: $model.autoTrim)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    AudioValueSlider(title: "Silence threshold", value: $model.threshold, range: -70 ... -20, step: 1,
                                     format: { "\(Int($0.rounded())) dB" })
                        .help("Silence threshold in decibels")
                        .accessibilityLabel("Silence threshold in decibels")
                        .disabled(!model.autoTrim)
                        .opacity(model.autoTrim ? 1 : 0.5)
                    status
                        .frame(minHeight: 30, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxHeight: .infinity, alignment: .top)
        } footer: {
            ToolFooter(session: session, primaryTitle: "Save Trimmed Copy", primaryEnabled: model.canSave, action: save) {
                Button {
                    model.playSelection()
                } label: {
                    Label("Play Selected Range", systemImage: "play.square")
                }
                .buttonStyle(TintedButtonStyle())
                .disabled(!model.isLoaded || model.player.playableURL == nil)
                .opacity(model.isLoaded && model.player.playableURL != nil ? 1 : 0.45)
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder private var status: some View {
        if !model.autoTrim {
            AudioNote("Finds quiet audio at the start and end and moves the handles past it.")
        } else if model.isDetecting {
            AudioProgressNote(text: "Detecting silence")
        } else if model.isSilent {
            AudioNote("The selected range is silent at this threshold. Lower the threshold or turn off automatic trimming.",
                      symbol: "exclamationmark.triangle.fill", tint: .orange)
        } else if let summary = model.detectionSummary {
            AudioNote(summary, symbol: "checkmark.circle.fill")
        }
    }

    private func save() {
        // Commit a Start or End value that is still being typed.
        session.window?.makeFirstResponder(nil)
        DispatchQueue.main.async { [model, session] in
            guard model.canSave else { return }
            let start = model.start
            let end = model.end
            model.player.pause()
            session.runPerItem { url, context in
                [try await TrimAudioProcessor.trim(url, start: start, end: end, context: context)]
            }
        }
    }
}

/// Waveform with trim handles, playhead and the playback/time row.
private struct TrimAudioTimeline: View {
    @ObservedObject var model: TrimAudioModel
    @ObservedObject var player: MediaPlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AudioTrimTrack(start: $model.start, end: $model.end, duration: max(model.duration, 0.01),
                           playhead: model.isLoaded ? player.currentTime : nil, samples: model.samples,
                           onScrub: { model.scrub(to: $0) })
            .frame(height: 108)
            .padding(.top, 4)
            .overlay {
                if !model.isLoaded { ProgressView().controlSize(.small) }
            }
            .disabled(!model.isLoaded)
            HStack {
                AudioNote("Drag the ends to trim", symbol: "arrow.left.and.right")
                Spacer()
                AudioNote("Drag to scrub and play from a time", symbol: "hand.draw")
            }
            if let message = player.unavailableMessage {
                AudioNote(message, symbol: "speaker.slash", tint: .orange)
            }
            PlaybackBar(player: player) {
                HStack(spacing: 12) {
                    SecondsField(title: "Start", seconds: $model.start, range: 0...max(0, model.end - 0.05))
                    SecondsField(title: "End", seconds: $model.end, range: min(model.start + 0.05, model.duration)...max(model.duration, 0.05))
                    Text("Length \(AudioText.time(model.length))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 96, alignment: .trailing)
                }
                .fixedSize()
            }
        }
    }
}
