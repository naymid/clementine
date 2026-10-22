import AppKit
import AVFoundation
import SwiftUI

// MARK: - Processing

struct BleepRange: Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double

    var length: Double { end - start }
}

enum BleepAudioProcessor {
    static let toneFrequency = 1000.0
    /// Peak level of the bleep tone (about -9 dBFS).
    static let toneAmplitude = 0.35
    static let defaultLength = 0.6
    static let minimumLength = 0.05

    /// Saves "<name>-bleeped.<ext>": the audio is silenced inside each range and a 1 kHz tone plays there instead.
    static func bleep(_ url: URL, ranges: [ClosedRange<Double>], context: JobContext) async throws -> URL {
        let info = try await AudioStreamInfo.probe(url)
        let merged = merge(ranges, duration: info.duration)
        guard !merged.isEmpty else { throw ProcessError.failed("Add at least one bleep range.") }
        let output = FileNaming.output(beside: url, suffix: "-bleeped", extension: url.pathExtension)
        let graph = filterGraph(ranges: merged, sampleRate: info.sampleRate, layout: info.layoutName, channels: info.channels)
        try await AudioOutput.encode(output: output, source: info, duration: info.duration, context: context, audioLabel: "bleeped") { mapping in
            ["-i", url.path, "-filter_complex", graph] + mapping + AudioOutput.codecArguments(for: output, source: info)
        }
        return output
    }

    /// Sorted ranges clamped to the audio, with overlapping or touching ranges joined.
    static func merge(_ ranges: [ClosedRange<Double>], duration: Double) -> [ClosedRange<Double>] {
        let limit = duration > 0 ? duration : .greatestFiniteMagnitude
        let clamped = ranges
            .map { max(0, $0.lowerBound)...min(limit, $0.upperBound) }
            .filter { $0.upperBound - $0.lowerBound >= 0.01 }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in clamped {
            if let last = merged.last, range.lowerBound <= last.upperBound + 0.001 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Timeline expression that is non-zero inside any range.
    static func insideExpression(_ ranges: [ClosedRange<Double>]) -> String {
        ranges.map { "between(t\\,\(AudioFFmpeg.number($0.lowerBound))\\,\(AudioFFmpeg.number($0.upperBound)))" }.joined(separator: "+")
    }

    /// Mutes the source inside the ranges and mixes in a sine tone that is only audible there.
    /// Small frames keep the switch points within a few milliseconds of the range edges.
    static func filterGraph(ranges: [ClosedRange<Double>], sampleRate: Int, layout: String, channels: Int) -> String {
        let inside = insideExpression(ranges)
        let format = "aformat=sample_fmts=fltp:sample_rates=\(sampleRate):channel_layouts=\(layout)"
        let gain = AudioFFmpeg.number(toneAmplitude * 8) // the sine source peaks at 1/8
        // Copy the tone into every channel at full level (an automatic upmix would lower it by 3 dB).
        let spread = "pan=\(layout)|" + (0..<max(1, channels)).map { "c\($0)=c0" }.joined(separator: "|")
        return [
            "[0:a]\(format),asetnsamples=n=256:p=0,volume=0:enable='\(inside)'[muted]",
            "sine=frequency=\(Int(toneFrequency)):sample_rate=\(sampleRate),volume=\(gain),\(spread),\(format),asetnsamples=n=256:p=0,volume=0:enable='not(\(inside))'[tone]",
            "[muted][tone]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[bleeped]",
        ].joined(separator: ";")
    }
}

/// Builds a live preview of the bleeps with AVFoundation: the source is muted inside each range
/// through an audio mix, and a tone track plays there. Rebuilding is instant, so edits are heard at once.
enum BleepPreviewComposer {
    private static var cachedTone: URL?

    /// A one-second 1 kHz tone at the bleep level (a whole number of cycles, so it loops cleanly).
    static func toneURL() throws -> URL {
        if let cachedTone, FileManager.default.fileExists(atPath: cachedTone.path) { return cachedTone }
        let url = AudioScratch.directory.appendingPathComponent("bleep-tone-1k.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            let sampleRate = 44_100.0
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate)),
                  let data = buffer.floatChannelData?[0] else { throw ProcessError.failed("The bleep tone could not be made.") }
            buffer.frameLength = AVAudioFrameCount(sampleRate)
            for index in 0..<Int(sampleRate) {
                data[index] = Float(BleepAudioProcessor.toneAmplitude * sin(2 * .pi * BleepAudioProcessor.toneFrequency * Double(index) / sampleRate))
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ]
            let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".wav")
            do {
                let file = try AVAudioFile(forWriting: temporary, settings: settings)
                try file.write(from: buffer)
            }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        cachedTone = url
        return url
    }

    static func composition(source: URL, ranges: [ClosedRange<Double>]) async throws -> (AVMutableComposition, AVMutableAudioMix) {
        let asset = AVURLAsset(url: source)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ProcessError.failed("This file has no audio track.")
        }
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        guard let main = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ProcessError.failed("The preview could not be prepared.")
        }
        try main.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero)
        let parameters = AVMutableAudioMixInputParameters(track: main)
        let merged = BleepAudioProcessor.merge(ranges, duration: duration.seconds)
        // Volume points are interpolated, so describe every stretch as a flat ramp:
        // full volume between bleeps, silence inside them.
        var volumeCursor = CMTime.zero
        for range in merged {
            let start = CMTime(seconds: range.lowerBound, preferredTimescale: 48_000)
            let end = CMTime(seconds: range.upperBound, preferredTimescale: 48_000)
            if start > volumeCursor {
                parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 1, timeRange: CMTimeRange(start: volumeCursor, end: start))
            }
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 0, timeRange: CMTimeRange(start: start, end: end))
            volumeCursor = end
        }
        if duration > volumeCursor {
            parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 1, timeRange: CMTimeRange(start: volumeCursor, end: duration))
        }
        if !merged.isEmpty {
            let toneAsset = AVURLAsset(url: try toneURL())
            guard let toneTrack = try await toneAsset.loadTracks(withMediaType: .audio).first,
                  let bleeps = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw ProcessError.failed("The preview could not be prepared.") }
            let toneLength = try await toneAsset.load(.duration)
            var cursor = CMTime.zero
            for range in merged {
                let start = CMTime(seconds: range.lowerBound, preferredTimescale: 48_000)
                let end = CMTime(seconds: range.upperBound, preferredTimescale: 48_000)
                if start > cursor { bleeps.insertEmptyTimeRange(CMTimeRange(start: cursor, end: start)) }
                var time = start
                while time < end {
                    let piece = CMTimeMinimum(toneLength, end - time)
                    try bleeps.insertTimeRange(CMTimeRange(start: .zero, duration: piece), of: toneTrack, at: time)
                    time = time + piece
                }
                cursor = end
            }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return (composition, mix)
    }

    @MainActor
    static func playerItem(source: URL, ranges: [ClosedRange<Double>]) async throws -> AVPlayerItem {
        let (composition, mix) = try await composition(source: source, ranges: ranges)
        let item = AVPlayerItem(asset: composition)
        item.audioMix = mix
        return item
    }

    /// Writes the preview mix to an M4A (used to check the preview headlessly).
    static func export(source: URL, ranges: [ClosedRange<Double>], to output: URL) async throws {
        let (composition, mix) = try await composition(source: source, ranges: ranges)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ProcessError.failed("The preview could not be exported.")
        }
        session.audioMix = mix
        try? FileManager.default.removeItem(at: output)
        try await session.export(to: output, as: .m4a)
    }
}

// MARK: - Model

@MainActor
final class BleepAudioModel: ObservableObject {
    let url: URL
    let player = MediaPlayerModel()

    @Published var ranges: [BleepRange] {
        didSet { if ranges != oldValue { schedulePreviewUpdate() } }
    }
    @Published var selection: BleepRange.ID?
    @Published private(set) var samples: [Float] = []
    @Published private(set) var duration: Double = 0
    @Published private(set) var isLoaded = false

    private let previewJob = AudioEditorJob()

    init(url: URL, ranges: [BleepRange] = [], selection: BleepRange.ID? = nil) {
        self.url = url
        self.ranges = ranges
        self.selection = selection
    }

    var mergedRanges: [ClosedRange<Double>] {
        BleepAudioProcessor.merge(ranges.map { $0.start...$0.end }, duration: duration)
    }

    var totalLength: Double { mergedRanges.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }

    func load() async {
        guard !isLoaded else { return }
        async let waveform: [Float]? = try? await WaveformLoader.samples(for: url, buckets: 420)
        await player.load(url)
        duration = player.duration
        if duration <= 0 { duration = (try? await AudioStreamInfo.probe(url).duration) ?? 0 }
        samples = await waveform ?? []
        isLoaded = true
        schedulePreviewUpdate(delay: 0)
    }

    func scrub(to seconds: Double) {
        player.seek(to: seconds, precise: false)
    }

    func addAtPlayhead() {
        guard duration > 0 else { return }
        let length = min(BleepAudioProcessor.defaultLength, duration)
        let start = min(max(0, player.currentTime), max(0, duration - length))
        let range = BleepRange(start: start, end: start + length)
        ranges.append(range)
        selection = range.id
    }

    func bleepEntireAudio() {
        guard duration > 0 else { return }
        let range = BleepRange(start: 0, end: duration)
        ranges = [range]
        selection = range.id
    }

    func deleteSelection() {
        guard let selection else { return }
        ranges.removeAll { $0.id == selection }
        self.selection = nil
    }

    func update(_ id: BleepRange.ID, start: Double, end: Double) {
        guard let index = ranges.firstIndex(where: { $0.id == id }) else { return }
        ranges[index].start = start
        ranges[index].end = end
    }

    /// Rebuilds the playback item so the bleeps are heard, keeping the play position.
    private func schedulePreviewUpdate(delay: Double = 0.15) {
        guard isLoaded, let source = player.playableURL else { return }
        let ranges = self.mergedRanges
        previewJob.start(after: delay) { [weak self] runner in
            guard let item = try? await BleepPreviewComposer.playerItem(source: source, ranges: ranges) else { return }
            guard let self, !runner.isCancelled else { return }
            let wasPlaying = self.player.isPlaying
            let time = self.player.currentTime
            self.player.player.replaceCurrentItem(with: item)
            self.player.seek(to: time)
            if wasPlaying { self.player.play() }
        }
    }
}

// MARK: - Editor

struct BleepAudioEditor: View {
    @ObservedObject var session: ToolSession
    @StateObject private var model: BleepAudioModel

    init(session: ToolSession, ranges: [BleepRange] = [], selectFirst: Bool = false) {
        self.session = session
        _model = StateObject(wrappedValue: BleepAudioModel(url: session.primaryURL, ranges: ranges,
                                                           selection: selectFirst ? ranges.first?.id : nil))
    }

    var body: some View {
        ToolScaffold(session: session) {
            VStack(alignment: .leading, spacing: 10) {
                BleepTimeline(model: model, player: model.player)
                AudioNote("Drag across the Bleep layer to add a section, then drag a clip or either edge to adjust it.",
                          symbol: "hand.draw")
                if let message = model.player.unavailableMessage {
                    AudioNote(message, symbol: "speaker.slash", tint: .orange)
                }
                Spacer(minLength: 0)
                BleepControls(model: model, player: model.player)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        } footer: {
            ToolFooter(session: session, primaryTitle: "Save Bleeped Copy", primaryEnabled: !model.ranges.isEmpty) {
                let ranges = model.mergedRanges
                guard !ranges.isEmpty else { return }
                model.player.pause()
                session.runPerItem { url, context in
                    [try await BleepAudioProcessor.bleep(url, ranges: ranges, context: context)]
                }
            } leading: {
                if model.ranges.isEmpty {
                    AudioNote("Add at least one bleep range.", symbol: "exclamationmark.circle")
                } else {
                    let count = model.mergedRanges.count
                    AudioNote("\(count) \(count == 1 ? "bleep" : "bleeps") · \(AudioText.seconds(model.totalLength))",
                              symbol: "waveform.badge.minus")
                }
            }
        }
        .task { await model.load() }
    }
}

/// The audio waveform over the Bleep layer, sharing one time axis.
private struct BleepTimeline: View {
    @ObservedObject var model: BleepAudioModel
    @ObservedObject var player: MediaPlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                laneLabel("Audio")
                ScrubbableWaveform(samples: model.samples, duration: model.duration, playhead: player.currentTime,
                                   onScrub: { model.scrub(to: $0) })
                    .overlay { bleepShading }
                    .overlay { if !model.isLoaded { ProgressView().controlSize(.small) } }
                    .help("Drag to scrub and play from a time")
            }
            .frame(height: 120)
            HStack(spacing: 8) {
                laneLabel("Bleep")
                BleepLayer(model: model, playhead: player.currentTime)
            }
            .frame(height: 40)
        }
    }

    private func laneLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 40, alignment: .leading)
    }

    /// Orange tint over the waveform where bleeps are.
    private var bleepShading: some View {
        GeometryReader { proxy in
            let duration = max(model.duration, 0.001)
            ForEach(model.ranges) { range in
                Rectangle()
                    .fill(Brand.buttonOrange.opacity(0.22))
                    .frame(width: max(1, CGFloat(range.length / duration) * proxy.size.width), height: proxy.size.height)
                    .offset(x: CGFloat(range.start / duration) * proxy.size.width)
            }
        }
        .allowsHitTesting(false)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The lane where bleeps are drawn, moved and resized.
private struct BleepLayer: View {
    @ObservedObject var model: BleepAudioModel
    var playhead: Double

    @State private var creating: (id: BleepRange.ID, anchor: Double)?
    @State private var moveOrigin: (id: BleepRange.ID, start: Double, end: Double)?

    private static let space = "bleepLayer"

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let height = proxy.size.height
            let duration = max(model.duration, 0.001)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                if model.ranges.isEmpty {
                    Text("Drag here to add a bleep")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: width, height: height)
                        .allowsHitTesting(false)
                }
                ForEach(model.ranges) { range in
                    clip(range, width: width, height: height, duration: duration)
                }
                Capsule()
                    .fill(Brand.buttonOrange.opacity(0.9))
                    .frame(width: 2, height: height)
                    .offset(x: CGFloat(min(1, max(0, playhead / duration))) * width - 1)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(createGesture(width: width, duration: duration))
            .coordinateSpace(name: Self.space)
        }
        .disabled(!model.isLoaded)
        .accessibilityLabel("Bleep layer")
    }

    private func time(at x: CGFloat, width: CGFloat, duration: Double) -> Double {
        Double(min(width, max(0, x)) / width) * duration
    }

    /// Drag on empty lane: draw a new bleep. Click: deselect and move the playhead.
    private func createGesture(width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let now = time(at: value.location.x, width: width, duration: duration)
                if let creating {
                    let lower = min(creating.anchor, now)
                    let upper = max(creating.anchor, now)
                    let end = min(duration, max(upper, lower + BleepAudioProcessor.minimumLength))
                    model.update(creating.id, start: min(lower, end - BleepAudioProcessor.minimumLength), end: end)
                } else if abs(value.translation.width) >= 3 {
                    let anchor = time(at: value.startLocation.x, width: width, duration: duration)
                    let range = BleepRange(start: min(anchor, now), end: max(max(anchor, now), min(anchor, now) + BleepAudioProcessor.minimumLength))
                    model.ranges.append(range)
                    model.selection = range.id
                    creating = (range.id, anchor)
                }
            }
            .onEnded { value in
                if creating == nil {
                    model.selection = nil
                    model.scrub(to: time(at: value.location.x, width: width, duration: duration))
                }
                creating = nil
            }
    }

    private func clip(_ range: BleepRange, width: CGFloat, height: CGFloat, duration: Double) -> some View {
        let selected = model.selection == range.id
        let x = CGFloat(range.start / duration) * width
        let clipWidth = max(8, CGFloat(range.length / duration) * width)
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Brand.buttonOrange.opacity(selected ? 1 : 0.72))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.white.opacity(selected ? 0.95 : 0.25), lineWidth: selected ? 2 : 1))
            .overlay {
                if clipWidth > 64 {
                    HStack(spacing: 3) {
                        Image(systemName: "waveform")
                        Text("Bleep")
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .leading) { edgeHandle(range, edge: .leading, width: width, duration: duration, handleWidth: min(9, clipWidth / 3)) }
            .overlay(alignment: .trailing) { edgeHandle(range, edge: .trailing, width: width, duration: duration, handleWidth: min(9, clipWidth / 3)) }
            .frame(width: clipWidth, height: height)
            .contentShape(Rectangle())
            .gesture(moveGesture(range, width: width, duration: duration))
            .offset(x: x)
            .help("Drag to move this bleep. Press Delete to remove it.")
    }

    /// Drag a clip to move it; a click selects it.
    private func moveGesture(_ range: BleepRange, width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if moveOrigin?.id != range.id {
                    moveOrigin = (range.id, range.start, range.end)
                    model.selection = range.id
                }
                guard let origin = moveOrigin else { return }
                let length = origin.end - origin.start
                let delta = Double(value.translation.width / width) * duration
                let start = min(max(0, origin.start + delta), max(0, duration - length))
                model.update(range.id, start: start, end: start + length)
            }
            .onEnded { _ in moveOrigin = nil }
    }

    private func edgeHandle(_ range: BleepRange, edge: HorizontalEdge, width: CGFloat, duration: Double, handleWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: handleWidth)
            .overlay(Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: 14))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { value in
                model.selection = range.id
                guard let current = model.ranges.first(where: { $0.id == range.id }) else { return }
                let now = time(at: value.location.x, width: width, duration: duration)
                if edge == .leading {
                    model.update(range.id, start: min(now, current.end - BleepAudioProcessor.minimumLength), end: current.end)
                } else {
                    model.update(range.id, start: current.start, end: max(now, current.start + BleepAudioProcessor.minimumLength))
                }
            })
            .help(edge == .leading ? "Drag to change where this bleep starts" : "Drag to change where this bleep ends")
    }
}

/// Playback and bleep editing buttons.
private struct BleepControls: View {
    @ObservedObject var model: BleepAudioModel
    @ObservedObject var player: MediaPlayerModel

    var body: some View {
        PlaybackBar(player: player) {
            HStack(spacing: 8) {
                Button {
                    model.addAtPlayhead()
                } label: {
                    Label("Add bleep at playhead", systemImage: "plus")
                }
                .buttonStyle(TintedButtonStyle())
                .help("Add a \(AudioText.seconds(BleepAudioProcessor.defaultLength)) bleep at the playhead")
                Button("Bleep Entire Audio") { model.bleepEntireAudio() }
                    .buttonStyle(TintedButtonStyle())
                Button {
                    model.deleteSelection()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(model.selection == nil)
                .opacity(model.selection == nil ? 0.4 : 1)
                .help("Delete the selected bleep (Delete)")
                .accessibilityLabel("Delete the selected bleep")
                .background {
                    // The Delete key types U+007F while KeyEquivalent.delete is U+0008; cover both,
                    // plus forward delete, so pressing either key removes the selected bleep.
                    ZStack {
                        Button("") { model.deleteSelection() }
                            .keyboardShortcut(KeyEquivalent("\u{7F}"), modifiers: [])
                        Button("") { model.deleteSelection() }
                            .keyboardShortcut(.deleteForward, modifiers: [])
                    }
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .disabled(model.selection == nil)
                    .accessibilityHidden(true)
                }
            }
            .disabled(!model.isLoaded)
        }
    }
}
