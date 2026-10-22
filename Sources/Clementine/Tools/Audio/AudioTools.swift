import SwiftUI

/// Editors for the audio tools: trim, normalize, channels, visualizer and bleep.
@MainActor
enum AudioTools: ToolGroup {
    static let tools: Set<FileTool> = [.trimAudio, .normalizeAudio, .audioChannels, .audioToVideo, .redactAudio]

    static func makeEditor(for session: ToolSession) -> ToolEditor? {
        switch session.tool {
        case .trimAudio:
            return ToolEditor(TrimAudioEditor(session: session), size: CGSize(width: 660, height: 450), minSize: CGSize(width: 560, height: 440))
        case .normalizeAudio:
            return ToolEditor(NormalizeAudioEditor(session: session), size: CGSize(width: 540, height: 570), minSize: CGSize(width: 500, height: 560))
        case .audioChannels:
            return ToolEditor(AudioChannelsEditor(session: session), size: CGSize(width: 560, height: 510), minSize: CGSize(width: 500, height: 500))
        case .audioToVideo:
            return ToolEditor(AudioVisualizerEditor(session: session), size: CGSize(width: 840, height: 560), minSize: CGSize(width: 740, height: 520))
        case .redactAudio:
            return ToolEditor(BleepAudioEditor(session: session), size: CGSize(width: 700, height: 400), minSize: CGSize(width: 620, height: 390))
        default:
            return nil
        }
    }

    static func runImmediately(_ session: ToolSession) {
        ToolCoordinator.shared.showUnavailable(session)
    }

    static func registerSnapshots() {
        registerTests()
        registerSnapshotVariants()
    }

    // MARK: - Headless tests: Clementine --tool-test <name> <files…> key=value…

    private static func registerTests() {
        ToolTestRegistry.tests["trimAudio"] = { files, options, context in
            let options = AudioTestOptions(values: options)
            var outputs: [URL] = []
            for file in files {
                let info = try await AudioStreamInfo.probe(file)
                var start = options.double("start", 0)
                var end = options.double("end", info.duration)
                if options.bool("auto") {
                    let threshold = options.double("threshold", -45)
                    guard let bounds = try await TrimAudioProcessor.contentBounds(file, thresholdDB: threshold, duration: info.duration, runner: context.runner) else {
                        throw ProcessError.failed("The selected range is silent at this threshold. Lower the threshold or turn off automatic trimming.")
                    }
                    print("silence: content \(AudioFFmpeg.number(bounds.start, digits: 3))...\(AudioFFmpeg.number(bounds.end, digits: 3)) of \(AudioFFmpeg.number(info.duration, digits: 3))")
                    start = bounds.start
                    end = bounds.end
                }
                outputs.append(try await TrimAudioProcessor.trim(file, start: start, end: end, context: context))
            }
            return outputs
        }

        ToolTestRegistry.tests["normalizeAudio"] = { files, options, context in
            let options = AudioTestOptions(values: options)
            var target = LoudnessTarget()
            if let preset = LoudnessPreset(rawValue: options.string("preset", "")), let values = preset.values {
                target.integrated = values.integrated
                target.truePeak = values.truePeak
            }
            target.integrated = options.double("lufs", target.integrated)
            target.range = options.double("lra", target.range)
            target.truePeak = options.double("tp", target.truePeak)
            var outputs: [URL] = []
            for file in files {
                if options.bool("preview") {
                    let info = try await AudioStreamInfo.probe(file)
                    let measured = try await NormalizeAudioProcessor.measure(file, target: target, runner: context.runner)
                    print("measured: I=\(measured.integrated) TP=\(measured.truePeak) LRA=\(measured.range) thresh=\(measured.threshold) offset=\(measured.targetOffset)")
                    let window = NormalizeAudioProcessor.previewWindow(duration: info.duration)
                    let preview = try await NormalizeAudioProcessor.renderPreview(file, target: target, measured: measured,
                                                                                  start: window.start, length: window.length, runner: context.runner)
                    let destination = FileNaming.output(beside: file, suffix: "-normalized-preview", extension: "m4a")
                    try FileManager.default.moveItem(at: preview, to: destination)
                    outputs.append(destination)
                } else {
                    outputs.append(try await NormalizeAudioProcessor.normalize(file, target: target, context: context))
                }
            }
            return outputs
        }

        ToolTestRegistry.tests["audioChannels"] = { files, options, context in
            let options = AudioTestOptions(values: options)
            let output = ChannelOutput(rawValue: options.string("output", "mono")) ?? .mono
            let left = options.double("left", 100) / 100
            let right = options.double("right", 100) / 100
            var outputs: [URL] = []
            for file in files {
                if let channel = options.values["preview"] {
                    // preview=left|right|output renders the editor's preview file beside the source.
                    let info = try await AudioStreamInfo.probe(file)
                    let filter: String
                    switch channel {
                    case "left": filter = AudioChannelsProcessor.channelFilter(channel: 0, sourceChannels: info.channels, volume: left)
                    case "right": filter = AudioChannelsProcessor.channelFilter(channel: 1, sourceChannels: info.channels, volume: right)
                    default: filter = AudioChannelsProcessor.panFilter(output: output, sourceChannels: info.channels, left: left, right: right)
                    }
                    let preview = try await AudioChannelsProcessor.renderPreview(file, filter: filter, runner: context.runner)
                    let destination = FileNaming.output(beside: file, suffix: "-preview-\(channel)", extension: "m4a")
                    try FileManager.default.moveItem(at: preview, to: destination)
                    outputs.append(destination)
                } else {
                    outputs.append(try await AudioChannelsProcessor.convert(file, output: output, left: left, right: right, context: context))
                }
            }
            return outputs
        }

        ToolTestRegistry.tests["audioToVideo"] = { files, options, context in
            let values = AudioTestOptions(values: options)
            let visualizer = visualizerOptions(from: options)
            var outputs: [URL] = []
            for file in files {
                if values.bool("frame") {
                    let info = try await AudioStreamInfo.probe(file)
                    var backdrop: URL?
                    if let image = visualizer.backdropImage {
                        let url = AudioScratch.file("jpg")
                        try await AudioVisualizerProcessor.writeBackdropInBackground(image: image, canvas: visualizer.canvas,
                                                                                     foreground: visualizer.style == .image, to: url)
                        backdrop = url
                    }
                    let destination = FileNaming.output(beside: file, suffix: "-visualizer-frame", extension: visualizer.style == .image ? "jpg" : "png")
                    if visualizer.style == .image, let backdrop {
                        try FileManager.default.moveItem(at: backdrop, to: destination)
                    } else {
                        let frame = try await AudioVisualizerProcessor.renderPreviewFrame(file, options: visualizer, duration: info.duration,
                                                                                          backdrop: backdrop, runner: context.runner)
                        try FileManager.default.moveItem(at: frame, to: destination)
                        AudioScratch.remove(backdrop)
                    }
                    outputs.append(destination)
                } else {
                    outputs.append(try await AudioVisualizerProcessor.render(file, options: visualizer, context: context))
                }
            }
            return outputs
        }

        ToolTestRegistry.tests["redactAudio"] = { files, options, context in
            let values = AudioTestOptions(values: options)
            var outputs: [URL] = []
            for file in files {
                let info = try await AudioStreamInfo.probe(file)
                let ranges = values.bool("entire") ? [0...info.duration] : parseRanges(values.string("ranges", ""))
                guard !ranges.isEmpty else { throw ProcessError.failed("Add at least one bleep range.") }
                if values.bool("preview") {
                    // Exports the editor's live AVFoundation preview mix so it can be measured.
                    let destination = FileNaming.output(beside: file, suffix: "-bleep-preview", extension: "m4a")
                    let playable = await PreviewSource.playableURL(for: file, info: try await MediaInfo.probe(file)) ?? file
                    try await BleepPreviewComposer.export(source: playable, ranges: ranges, to: destination)
                    outputs.append(destination)
                } else {
                    outputs.append(try await BleepAudioProcessor.bleep(file, ranges: ranges, context: context))
                }
            }
            return outputs
        }
    }

    /// "0.5-1.2,2-2.6" → [0.5...1.2, 2...2.6]
    private static func parseRanges(_ text: String) -> [ClosedRange<Double>] {
        text.split(separator: ",").compactMap { part in
            let bounds = part.split(separator: "-").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard bounds.count == 2, bounds[1] > bounds[0] else { return nil }
            return bounds[0]...bounds[1]
        }
    }

    private static func visualizerOptions(from values: [String: String]) -> VisualizerOptions {
        var options = VisualizerOptions()
        if let style = values["style"].flatMap(VisualizerOptions.Style.init(rawValue:)) { options.style = style }
        if let canvas = values["canvas"].flatMap(VisualizerOptions.Canvas.init(rawValue:)) { options.canvas = canvas }
        if let background = values["background"].flatMap(VisualizerOptions.Background.init(rawValue:)) { options.background = background }
        if let color = values["color"] {
            if let preset = VisualizerOptions.WaveColor(rawValue: color) {
                options.waveColor = preset
            } else {
                options.waveColor = .custom
                options.customColorHex = color.uppercased()
            }
        }
        if let hex = values["bgcolor"] { options.backgroundColorHex = hex.uppercased() }
        if let image = values["image"] {
            let url = URL(fileURLWithPath: image)
            if options.style == .image { options.stillImage = url } else { options.backgroundImage = url }
        }
        return options
    }

    // MARK: - Snapshot states: Clementine --snapshot audio-… out.png --files …

    private static func registerSnapshotVariants() {
        func value(_ flag: String, in arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        func entry<V: View>(_ tool: FileTool, files: [URL], size: CGSize, _ make: (ToolSession) -> V) -> SnapshotRegistry.Entry {
            let session = ToolSession(tool: tool, urls: files)
            return SnapshotRegistry.Entry(view: AnyView(make(session).environmentObject(session)), size: size)
        }
        SnapshotRegistry.builders["audio-trim-auto"] = { files, _ in
            entry(.trimAudio, files: files, size: CGSize(width: 660, height: 450)) { TrimAudioEditor(session: $0, autoTrim: true) }
        }
        SnapshotRegistry.builders["audio-channels-stereo"] = { files, _ in
            entry(.audioChannels, files: files, size: CGSize(width: 560, height: 510)) { AudioChannelsEditor(session: $0, output: .stereo) }
        }
        SnapshotRegistry.builders["audio-bleep-demo"] = { files, arguments in
            let ranges = parseRanges(value("--ranges", in: arguments) ?? "0.8-1.6,3.1-3.5").map { BleepRange(start: $0.lowerBound, end: $0.upperBound) }
            return entry(.redactAudio, files: files, size: CGSize(width: 700, height: 400)) {
                BleepAudioEditor(session: $0, ranges: ranges, selectFirst: true)
            }
        }
        // Any audio editor driven by scripted mouse/key events before the snapshot is taken.
        SnapshotRegistry.builders["audio-scripted"] = { files, arguments in
            let tool = value("--tool", in: arguments).flatMap(FileTool.init(rawValue:)) ?? .redactAudio
            let steps = AudioSnapshotScript.parse(value("--script", in: arguments) ?? "")
            let session = ToolSession(tool: tool, urls: files)
            let view: AnyView
            if tool == .redactAudio, let text = value("--ranges", in: arguments) {
                let ranges = parseRanges(text).map { BleepRange(start: $0.lowerBound, end: $0.upperBound) }
                view = AnyView(BleepAudioEditor(session: session, ranges: ranges))
            } else if let editor = makeEditor(for: session) {
                view = editor.view
            } else {
                view = AnyView(EmptyView())
            }
            let size = makeEditor(for: session)?.size ?? CGSize(width: 600, height: 400)
            return SnapshotRegistry.Entry(view: AnyView(view.background(AudioSnapshotScript(steps: steps)).environmentObject(session)), size: size)
        }
        SnapshotRegistry.builders["audio-rangetrack-probe"] = { _, arguments in
            let steps = AudioSnapshotScript.parse(value("--script", in: arguments) ?? "")
            return SnapshotRegistry.Entry(view: AnyView(AudioSnapshotScript.RangeTrackProbe(withField: arguments.contains("--with-field")).background(AudioSnapshotScript(steps: steps))),
                                          size: CGSize(width: 660, height: 200))
        }
        SnapshotRegistry.builders["audio-visualizer"] = { files, arguments in
            var values: [String: String] = [:]
            for key in ["style", "canvas", "background", "color", "bgcolor", "image"] {
                if let found = value("--\(key)", in: arguments) { values[key] = found }
            }
            let options = visualizerOptions(from: values)
            return entry(.audioToVideo, files: files, size: CGSize(width: 840, height: 560)) { AudioVisualizerEditor(session: $0, options: options) }
        }
    }
}
