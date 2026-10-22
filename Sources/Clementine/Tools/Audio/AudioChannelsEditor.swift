import AppKit
import SwiftUI

// MARK: - Processing

enum ChannelOutput: String, CaseIterable, Hashable {
    case mono, stereo

    var title: String { self == .mono ? "Mono" : "Stereo" }
}

enum AudioChannelsProcessor {
    /// Writes "<name>-mono.<ext>" or "<name>-stereo.<ext>" with the left and right volumes applied (1 = 100%).
    static func convert(_ url: URL, output: ChannelOutput, left: Double, right: Double, context: JobContext) async throws -> URL {
        let info = try await AudioStreamInfo.probe(url)
        let destination = FileNaming.output(beside: url, suffix: output == .mono ? "-mono" : "-stereo", extension: url.pathExtension)
        let filter = panFilter(output: output, sourceChannels: info.channels, left: left, right: right)
        try await AudioOutput.encode(output: destination, source: info, duration: info.duration, context: context) { mapping in
            ["-i", url.path] + mapping + ["-af", filter] + AudioOutput.codecArguments(for: destination, source: info)
        }
        return destination
    }

    /// The pan filter for the output layout. Mono sums the two sides at half gain each, so a
    /// centered sound keeps its level. Sources with more than two channels are folded to stereo first.
    static func panFilter(output: ChannelOutput, sourceChannels: Int, left: Double, right: Double) -> String {
        let l = max(0, left)
        let r = max(0, right)
        let prefix = sourceChannels > 2 ? "aformat=channel_layouts=stereo," : ""
        func gain(_ value: Double) -> String { AudioFFmpeg.number(value) }
        if sourceChannels <= 1 {
            switch output {
            case .mono: return "pan=mono|c0=\(gain((l + r) / 2))*c0"
            case .stereo: return "pan=stereo|c0=\(gain(l))*c0|c1=\(gain(r))*c0"
            }
        }
        switch output {
        case .mono: return prefix + "pan=mono|c0=\(gain(l / 2))*c0+\(gain(r / 2))*c1"
        case .stereo: return prefix + "pan=stereo|c0=\(gain(l))*c0|c1=\(gain(r))*c1"
        }
    }

    /// One source channel (0 left, 1 right) at `volume`, as mono so it plays in both ears.
    static func channelFilter(channel: Int, sourceChannels: Int, volume: Double) -> String {
        let prefix = sourceChannels > 2 ? "aformat=channel_layouts=stereo," : ""
        let index = sourceChannels <= 1 ? 0 : min(1, max(0, channel))
        return prefix + "pan=mono|c0=\(AudioFFmpeg.number(max(0, volume)))*c\(index)"
    }

    /// Renders up to `limit` seconds through `filter` into a temporary M4A for previewing.
    static func renderPreview(_ url: URL, filter: String, limit: Double = 120, runner: ProcessRunner) async throws -> URL {
        let output = AudioScratch.file("m4a")
        do {
            try await AudioFFmpeg.run(["-t", AudioFFmpeg.number(limit), "-i", url.path, "-vn", "-af", filter,
                                       "-c:a", "aac", "-b:a", "192k", output.path], runner: runner)
        } catch {
            AudioScratch.remove(output)
            throw error
        }
        return output
    }
}

// MARK: - Model

@MainActor
final class AudioChannelsModel: ObservableObject {
    /// What the preview player is playing: a source channel or the complete output.
    enum Preview: Hashable { case channel(Int), output }

    let url: URL
    let player = MediaPlayerModel()

    @Published var output: ChannelOutput = .mono
    /// Volumes in percent, 0...200.
    @Published var leftVolume: Double = 100
    @Published var rightVolume: Double = 100
    @Published private(set) var channelSamples: [[Float]] = []
    @Published private(set) var sourceChannels = 2
    @Published private(set) var isLoaded = false
    @Published private(set) var loadError: String?
    @Published private(set) var playing: Preview?
    @Published private(set) var rendering: Preview?
    @Published private(set) var previewError: String?

    private var previewURL: URL?
    private let previewJob = AudioEditorJob()

    init(url: URL, output: ChannelOutput = .mono) {
        self.url = url
        self.output = output
    }

    deinit {
        if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
    }

    var isMonoSource: Bool { sourceChannels <= 1 }

    func load() async {
        guard !isLoaded else { return }
        do {
            let info = try await AudioStreamInfo.probe(url)
            sourceChannels = info.channels
            let count = info.channels <= 1 ? 1 : 2
            channelSamples = try await WaveformLoader.channels(for: url, buckets: 320, channelCount: count)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "This audio could not be read."
        }
        isLoaded = true
    }

    /// Plays one source channel, or stops it when it is already playing.
    func toggleChannel(_ index: Int) {
        let volume = (index == 0 ? leftVolume : rightVolume) / 100
        toggle(.channel(index), filter: AudioChannelsProcessor.channelFilter(channel: index, sourceChannels: sourceChannels, volume: volume))
    }

    /// Plays the complete Mono or Stereo output with the current balance.
    func toggleOutput() {
        toggle(.output, filter: AudioChannelsProcessor.panFilter(output: output, sourceChannels: sourceChannels,
                                                                  left: leftVolume / 100, right: rightVolume / 100))
    }

    func stop() {
        previewJob.cancel()
        player.pause()
        playing = nil
        rendering = nil
    }

    /// Called when the player stops on its own at the end of a preview.
    func playerStopped() {
        if rendering == nil { playing = nil }
    }

    private func toggle(_ preview: Preview, filter: String) {
        if playing == preview || rendering == preview {
            stop()
            return
        }
        stop()
        previewError = nil
        rendering = preview
        let url = self.url
        previewJob.start { [weak self] runner in
            do {
                let rendered = try await AudioChannelsProcessor.renderPreview(url, filter: filter, runner: runner)
                guard let self, !runner.isCancelled else {
                    AudioScratch.remove(rendered)
                    return
                }
                await self.player.load(rendered)
                AudioScratch.remove(self.previewURL)
                self.previewURL = rendered
                guard self.rendering == preview else { return }
                self.rendering = nil
                guard self.player.playableURL != nil else {
                    self.previewError = "This preview could not be played. You can still convert the channels."
                    return
                }
                self.player.seek(to: 0)
                self.playing = preview
                self.player.play()
            } catch {
                guard let self, !runner.isCancelled else { return }
                self.rendering = nil
                self.previewError = "This preview could not be prepared. You can still convert the channels."
            }
        }
    }
}

// MARK: - Editor

struct AudioChannelsEditor: View {
    @ObservedObject var session: ToolSession
    @StateObject private var model: AudioChannelsModel

    init(session: ToolSession, output: ChannelOutput = .mono) {
        self.session = session
        _model = StateObject(wrappedValue: AudioChannelsModel(url: session.primaryURL, output: output))
    }

    var body: some View {
        ToolScaffold(session: session) {
            VStack(alignment: .leading, spacing: 14) {
                ToolSection {
                    ToolSettingRow("Output") {
                        ToolSegmented(selection: $model.output, options: ChannelOutput.allCases.map { ($0, $0.title) })
                    }
                    AudioNote("Choose Mono or Stereo for a file with an audio track.")
                }
                ToolSection(sourceTitle) {
                    if let error = model.loadError {
                        AudioNote(error, symbol: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    if model.isMonoSource {
                        ChannelRow(model: model, title: "Mono", index: 0,
                                   samples: model.channelSamples.first ?? [],
                                   level: (model.leftVolume + model.rightVolume) / 200)
                        AudioNote("This file has one channel. Left and right volume set the level of each side of the output.")
                    } else {
                        ChannelRow(model: model, title: "Left", index: 0,
                                   samples: model.channelSamples.first ?? [], level: model.leftVolume / 100)
                        ChannelRow(model: model, title: "Right", index: 1,
                                   samples: model.channelSamples.count > 1 ? model.channelSamples[1] : [], level: model.rightVolume / 100)
                    }
                    Divider().opacity(0.5)
                    AudioValueSlider(title: "Left volume", value: $model.leftVolume, range: 0...200, step: 1,
                                     format: { "\(Int($0.rounded()))%" })
                    AudioValueSlider(title: "Right volume", value: $model.rightVolume, range: 0...200, step: 1,
                                     format: { "\(Int($0.rounded()))%" })
                }
                outputPreview
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxHeight: .infinity, alignment: .top)
        } footer: {
            ToolFooter(session: session, primaryTitle: "Convert Channels", primaryEnabled: model.loadError == nil) {
                let output = model.output
                let left = model.leftVolume / 100
                let right = model.rightVolume / 100
                model.stop()
                session.runPerItem { url, context in
                    [try await AudioChannelsProcessor.convert(url, output: output, left: left, right: right, context: context)]
                }
            } leading: {
                Button("Reset Volumes") {
                    model.leftVolume = 100
                    model.rightVolume = 100
                }
                .buttonStyle(TintedButtonStyle())
                .disabled(model.leftVolume == 100 && model.rightVolume == 100)
                .opacity(model.leftVolume == 100 && model.rightVolume == 100 ? 0.45 : 1)
            }
        }
        .task { await model.load() }
        .onReceive(model.player.$isPlaying) { playing in
            if !playing { model.playerStopped() }
        }
        .onChange(of: model.output) { _, _ in
            if model.playing == .output || model.rendering == .output { model.stop() }
        }
    }

    private var sourceTitle: String {
        session.urls.count > 1 ? "Channels · \(session.primaryURL.lastPathComponent)" : "Channels"
    }

    private var outputPreview: some View {
        let isPlaying = model.playing == .output
        let title = "Play \(model.output.title) Output"
        return HStack(spacing: 10) {
            AudioRoundButton(symbol: isPlaying ? "stop.fill" : "play.fill",
                             help: "Play the complete Mono or Stereo output with the selected volume balance",
                             isActive: isPlaying, isBusy: model.rendering == .output) {
                model.toggleOutput()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!model.isLoaded || model.loadError != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(isPlaying ? "Playing \(model.output.title) Output" : title)
                    .font(.system(size: 13, weight: .medium))
                if let error = model.previewError {
                    AudioNote(error, tint: .orange)
                } else {
                    AudioNote("Hear the complete output with the selected volume balance.")
                }
            }
            Spacer()
        }
        .padding(.horizontal, 2)
    }
}

/// A source channel's waveform with a play button. The waveform follows the channel's volume.
private struct ChannelRow: View {
    @ObservedObject var model: AudioChannelsModel
    var title: String
    var index: Int
    var samples: [Float]
    var level: Double

    var body: some View {
        let isPlaying = model.playing == .channel(index)
        HStack(spacing: 10) {
            AudioRoundButton(symbol: isPlaying ? "stop.fill" : "play.fill",
                             help: isPlaying ? "Stop channel preview" : "Play this channel",
                             size: 26, isActive: isPlaying, isBusy: model.rendering == .channel(index)) {
                model.toggleChannel(index)
            }
            .disabled(!model.isLoaded || model.loadError != nil)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06))
                if model.isLoaded {
                    WaveformView(samples: samples.map { min(1, $0 * Float(level)) },
                                 color: level > 0 ? Brand.buttonOrange.opacity(0.85) : Color.primary.opacity(0.25))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 46)
        }
    }
}
