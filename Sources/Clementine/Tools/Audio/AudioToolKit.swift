import AppKit
import AVFoundation
import SwiftUI

// MARK: - Stream facts

/// Facts about a file's first audio stream, used to pick encoder settings that match the source.
struct AudioStreamInfo {
    var duration: Double = 0
    var sampleRate = 44_100
    var channels = 2
    var channelLayout = ""
    var codec = ""
    /// Bits per second of the audio stream (or the whole file), 0 when unknown.
    var bitRate = 0
    /// Bits per sample for PCM and FLAC sources, 0 when unknown.
    var bitsPerSample = 0
    var sampleFormat = ""
    var hasCoverArt = false

    /// A layout name ffmpeg's aformat filter accepts.
    var layoutName: String {
        if !channelLayout.isEmpty, channelLayout != "unknown" { return channelLayout }
        switch channels {
        case 1: return "mono"
        case 2: return "stereo"
        default: return "\(max(1, channels))c"
        }
    }

    static func probe(_ url: URL) async throws -> AudioStreamInfo {
        guard let ffprobe = ToolPaths.ffprobe else { throw ProcessError.missingTool("ffmpeg") }
        let result = try await ProcessRunner().run(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        guard let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw ProcessError.failed("This file could not be read.")
        }
        var info = AudioStreamInfo()
        var foundAudio = false
        var formatBitRate = 0
        if let format = json["format"] as? [String: Any] {
            info.duration = Double(format["duration"] as? String ?? "") ?? 0
            formatBitRate = Int(format["bit_rate"] as? String ?? "") ?? 0
        }
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let type = stream["codec_type"] as? String
            if type == "audio", !foundAudio {
                foundAudio = true
                info.codec = stream["codec_name"] as? String ?? ""
                info.sampleRate = Int(stream["sample_rate"] as? String ?? "") ?? 44_100
                info.channels = stream["channels"] as? Int ?? 2
                info.channelLayout = stream["channel_layout"] as? String ?? ""
                info.bitRate = Int(stream["bit_rate"] as? String ?? "") ?? 0
                info.sampleFormat = stream["sample_fmt"] as? String ?? ""
                let raw = Int(stream["bits_per_raw_sample"] as? String ?? "") ?? 0
                info.bitsPerSample = raw > 0 ? raw : (stream["bits_per_sample"] as? Int ?? 0)
                if info.duration <= 0 { info.duration = Double(stream["duration"] as? String ?? "") ?? 0 }
            } else if type == "video" {
                let disposition = stream["disposition"] as? [String: Any]
                if (disposition?["attached_pic"] as? Int) == 1 { info.hasCoverArt = true }
            }
        }
        guard foundAudio else { throw ProcessError.failed("This file has no audio track.") }
        if info.bitRate == 0 { info.bitRate = formatBitRate }
        return info
    }
}

// MARK: - Output encoding

enum AudioOutput {
    private static let lossyExtensions: Set<String> = ["mp3", "m4a", "aac", "mp4", "ogg", "oga", "opus", "wma", "webm"]

    /// Encoder arguments that write `output` in its own format, close to the source's quality.
    static func codecArguments(for output: URL, source: AudioStreamInfo) -> [String] {
        let ext = output.pathExtension.lowercased()
        var arguments = FFmpegTool.audioCodecArguments(for: output)
        if lossyExtensions.contains(ext), let index = arguments.firstIndex(of: "-b:a"), index + 1 < arguments.count {
            // Match the source bitrate, within a range that keeps quality reasonable.
            let cap = ext == "opus" ? 256 : (ext == "wma" ? 192 : 320)
            let sourceKbps = source.bitRate > 0 ? Int((Double(source.bitRate) / 1000).rounded()) : 0
            let kbps = sourceKbps > 0 ? min(cap, max(128, sourceKbps)) : min(cap, 192)
            arguments[index + 1] = "\(kbps)k"
        }
        let highDepth = source.bitsPerSample > 16 || ["s32", "s32p", "flt", "fltp", "dbl", "dblp"].contains(source.sampleFormat)
        switch ext {
        case "m4a" where source.codec == "alac", "mp4" where source.codec == "alac":
            // Apple Lossless stays lossless.
            arguments = ["-c:a", "alac"]
        case "wav", "wave":
            if source.sampleFormat.hasPrefix("flt") || source.sampleFormat.hasPrefix("dbl") {
                arguments = ["-c:a", "pcm_f32le"]
            } else if highDepth {
                arguments = ["-c:a", "pcm_s24le"]
            } else {
                arguments = ["-c:a", "pcm_s16le"]
            }
        case "aiff", "aif", "aifc":
            arguments = ["-c:a", highDepth ? "pcm_s24be" : "pcm_s16be"]
        case "flac":
            arguments = source.bitsPerSample > 16
                ? ["-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24"]
                : ["-c:a", "flac", "-sample_fmt", "s16"]
        default:
            break
        }
        // Keep the source sample rate (loudnorm, for one, resamples to 192 kHz internally).
        switch ext {
        case "opus":
            arguments += ["-ar", "48000"]
        case "mp3":
            arguments += ["-ar", "\(min(48_000, max(8_000, source.sampleRate)))"]
        default:
            if source.sampleRate >= 8_000 { arguments += ["-ar", "\(source.sampleRate)"] }
        }
        return arguments
    }

    /// Stream mapping for an audio-only output: the audio (or a filter output label),
    /// the cover art when the container can hold it, and the source tags.
    static func mapArguments(for output: URL, source: AudioStreamInfo, audioLabel: String? = nil, includeCoverArt: Bool) -> [String] {
        var arguments = ["-map", audioLabel.map { "[\($0)]" } ?? "0:a:0"]
        let ext = output.pathExtension.lowercased()
        if includeCoverArt, source.hasCoverArt, ["mp3", "m4a", "flac"].contains(ext) {
            arguments += ["-map", "0:v:0", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
        } else {
            arguments += ["-vn"]
        }
        arguments += ["-map_metadata", "0"]
        if ext == "mp3" { arguments += ["-id3v2_version", "3"] }
        return arguments
    }

    /// Runs an encode that writes `output`, first keeping cover art, then without it if
    /// the container rejects the picture. Removes partial output on failure.
    static func encode(output: URL, source: AudioStreamInfo, duration: Double, context: JobContext,
                       progress: ClosedRange<Double> = 0...1, audioLabel: String? = nil,
                       arguments: (_ mapping: [String]) -> [String]) async throws {
        let attempts = source.hasCoverArt ? [true, false] : [false]
        var lastError: Error?
        for keepCover in attempts {
            let mapping = mapArguments(for: output, source: source, audioLabel: audioLabel, includeCoverArt: keepCover)
            do {
                try await AudioFFmpeg.run(arguments(mapping) + [output.path], duration: duration, context: context, progress: progress)
                return
            } catch {
                try? FileManager.default.removeItem(at: output)
                if case ProcessError.cancelled = error { throw error }
                if context.isCancelled { throw ProcessError.cancelled }
                lastError = error
            }
        }
        throw lastError ?? ProcessError.failed("The audio could not be saved.")
    }
}

// MARK: - ffmpeg

enum AudioFFmpeg {
    static func executable() throws -> String {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw ProcessError.missingTool("ffmpeg") }
        return ffmpeg
    }

    /// Runs ffmpeg for a job, mapping "time=" progress into `progress`. Returns stderr.
    @discardableResult
    static func run(_ arguments: [String], duration: Double, context: JobContext,
                    progress range: ClosedRange<Double> = 0...1) async throws -> String {
        let ffmpeg = try executable()
        let result = try await context.runner.run(ffmpeg, ["-y", "-hide_banner", "-nostdin"] + arguments) { line in
            guard duration > 0, let seconds = FFmpegProgress.seconds(in: line) else { return }
            context.progress(range.lowerBound + min(1, max(0, seconds / duration)) * (range.upperBound - range.lowerBound))
        }
        return result.stderr
    }

    /// Runs ffmpeg for an editor preview or measurement. Cancel through `runner`. Returns stderr.
    @discardableResult
    static func run(_ arguments: [String], runner: ProcessRunner) async throws -> String {
        let ffmpeg = try executable()
        return try await runner.run(ffmpeg, ["-y", "-hide_banner", "-nostdin"] + arguments).stderr
    }

    /// Formats a number for a filter argument.
    static func number(_ value: Double, digits: Int = 4) -> String {
        String(format: "%.\(digits)f", value)
    }
}

// MARK: - Scratch files

enum AudioScratch {
    static var directory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Clementine-audio-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func file(_ ext: String) -> URL {
        directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Background work for editors

/// One cancellable, optionally debounced background task with its own ffmpeg runner.
/// Starting a new one cancels the previous one.
@MainActor
final class AudioEditorJob {
    private var task: Task<Void, Never>?
    private var runner: ProcessRunner?

    var isActive: Bool { task != nil }

    func start(after delay: Double = 0, _ work: @escaping @MainActor (ProcessRunner) async -> Void) {
        cancel()
        let runner = ProcessRunner()
        self.runner = runner
        task = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, !runner.isCancelled else { return }
            await work(runner)
            if self?.runner === runner {
                self?.task = nil
                self?.runner = nil
            }
        }
    }

    func cancel() {
        task?.cancel()
        runner?.cancel()
        task = nil
        runner = nil
    }

    deinit {
        task?.cancel()
        runner?.cancel()
    }
}

// MARK: - Shared views

enum AudioText {
    static func time(_ seconds: Double) -> String {
        FileNaming.formatTime(seconds, showsFraction: true)
    }

    static func seconds(_ seconds: Double) -> String {
        String(format: "%.2f s", seconds)
    }
}

/// Small secondary text used for hints and status lines.
struct AudioNote: View {
    var text: String
    var symbol: String?
    var tint: Color?

    init(_ text: String, symbol: String? = nil, tint: Color? = nil) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(tint ?? Color.secondary)
    }
}

/// Status line with a small spinner, e.g. "Detecting silence".
struct AudioProgressNote: View {
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

/// Round play/stop button matching PlaybackBar's.
struct AudioRoundButton: View {
    var symbol: String
    var help: String
    var size: CGFloat = 30
    var isActive = false
    var isBusy = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(isActive ? Brand.buttonOrange : Color.primary.opacity(0.08))
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(isActive ? Color.white : Color.primary)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Labeled slider with a wider value readout than ToolSlider, for units like "dBTP".
struct AudioValueSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12.5))
                .frame(width: 112, alignment: .leading)
            // Rounded through the binding rather than `step:`, which would draw a tick per step.
            Slider(value: Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, ($0 / step).rounded() * step)) }),
                   in: range)
                .accessibilityLabel(title)
            Text(format(value))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
    }
}

/// Waveform with a playhead. Click or drag to scrub.
struct ScrubbableWaveform: View {
    var samples: [Float]
    var duration: Double
    var playhead: Double
    var color: Color = Color.primary.opacity(0.5)
    var onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                WaveformView(samples: samples, color: color)
                    .padding(.vertical, 4)
                if duration > 0 {
                    Capsule()
                        .fill(Brand.buttonOrange)
                        .frame(width: 2, height: proxy.size.height)
                        .offset(x: CGFloat(min(1, max(0, playhead / duration))) * width - 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard duration > 0 else { return }
                onScrub(Double(min(width, max(0, value.location.x)) / width) * duration)
            })
        }
    }
}

/// Opens an image chooser, as a sheet on `window` when possible.
@MainActor
enum AudioImagePicker {
    static func choose(message: String, window: NSWindow?, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = message
        panel.prompt = "Choose"
        if let window {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { completion(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }
}

extension Color {
    /// "RRGGBB" in sRGB for ffmpeg color arguments.
    var hexRGB: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        func channel(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", channel(color.redComponent), channel(color.greenComponent), channel(color.blueComponent))
    }

    init?(hexRGB: String) {
        var text = hexRGB.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.hasPrefix("0x") || text.hasPrefix("0X") { text.removeFirst(2) }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255, opacity: 1)
    }
}

/// Parses "key=value" options passed to headless tool tests.
struct AudioTestOptions {
    var values: [String: String]

    func double(_ key: String, _ fallback: Double) -> Double { values[key].flatMap(Double.init) ?? fallback }
    func string(_ key: String, _ fallback: String) -> String { values[key] ?? fallback }
    func bool(_ key: String) -> Bool { ["1", "true", "yes", "on"].contains(values[key]?.lowercased() ?? "") }
}
