import SwiftUI

// MARK: - Processing

enum VideoSpeedProcessor {
    static let range: ClosedRange<Double> = 0.25...4
    static let presets: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]

    /// "2", "0.5", "1.25"
    static func label(_ speed: Double) -> String {
        var text = String(format: "%.2f", speed)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// atempo steps between 0.5 and 2 whose product is `speed`, so pitch stays natural.
    static func atempoChain(_ speed: Double) -> String {
        var factors: [Double] = []
        var remaining = speed
        while remaining > 2.0001 {
            factors.append(2)
            remaining /= 2
        }
        while remaining < 0.4999 {
            factors.append(0.5)
            remaining /= 0.5
        }
        factors.append(remaining)
        return factors.map { "atempo=\(VideoExport.number($0))" }.joined(separator: ",")
    }

    /// Saves a copy at `speed` (0.25–4) as "<name>-2x.<ext>". Audio is pitch-corrected or removed.
    static func change(_ source: URL, speed: Double, keepAudio: Bool, context: JobContext) async throws -> URL {
        guard range.contains(speed) else { throw ProcessError.failed("Choose a speed between 0.25 and 4.") }
        let info = try await VideoExport.probe(source)
        let output = VideoExport.output(for: source, suffix: "-\(label(speed))x")
        let fps = VideoExport.number(VideoExport.frameRate(info))
        var arguments = ["-i", source.path, "-map", "0:V:0",
                         "-filter:v", "setpts=PTS/\(VideoExport.number(speed)),fps=\(fps),\(VideoExport.evenSize)"]
        arguments += FFmpegTool.videoCodecArguments(for: output)
        if keepAudio && info.hasAudio {
            arguments += ["-map", "0:a:0", "-filter:a", atempoChain(speed)] + FFmpegTool.audioCodecArguments(for: output)
        } else {
            arguments += ["-an"]
        }
        arguments += ["-map_metadata", "0"] + VideoExport.containerArguments(for: output)
        try await VideoExport.run(arguments, output: output, duration: info.duration / speed, context: context)
        return output
    }
}

// MARK: - Editor

struct ChangeVideoSpeedEditor: View {
    @ObservedObject var session: ToolSession
    @StateObject private var player = MediaPlayerModel()
    @State private var speed: Double = 2
    @State private var keepAudio = true
    @State private var typedSpeed: Double = 2
    @State private var invalidEntry = false

    private var url: URL { session.primaryURL }
    private var hasAudio: Bool { player.info.hasAudio }

    var body: some View {
        ToolScaffold(session: session, subtitle: VideoText.subtitle(url, player.info)) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 10) {
                    VideoStage(player: player, source: url) { videoRect in
                        if player.isPlaying {
                            Text("\(VideoSpeedProcessor.label(speed))×")
                                .font(.system(size: 12, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Brand.buttonOrange))
                                .position(x: max(36, videoRect.minX + 32), y: max(18, videoRect.minY + 18))
                        }
                    }
                    .frame(minWidth: 320, minHeight: 220)
                    PlaybackBar(player: player) {
                        Text("Preview at \(VideoSpeedProcessor.label(speed))×")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                sidebar
                    .frame(width: 262)
            }
            .padding(16)
            .background(VideoKeyMonitor { _ in false })
        } footer: {
            ToolFooter(session: session, primaryTitle: "Save Copy",
                       primaryEnabled: player.duration > 0 && abs(speed - 1) > 0.001, action: save) {
                if player.duration > 0 {
                    Text("\(VideoText.time(player.duration)) → \(VideoText.time(player.duration / speed))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            await player.load(url)
            player.rate = Float(speed)
            player.player.isMuted = !keepAudio
        }
        .onChange(of: speed) {
            player.rate = Float(speed)
            typedSpeed = speed
        }
        .onChange(of: keepAudio) { player.player.isMuted = !keepAudio }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolSection("Speed") {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(VideoSpeedProcessor.label(speed))×")
                        .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Brand.buttonOrange)
                    Spacer()
                    TextField("Speed", value: Binding(get: { typedSpeed }, set: { setTyped($0) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12).monospacedDigit())
                        .frame(width: 54)
                        .accessibilityLabel("Speed multiplier")
                    Text("×").foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { log2(speed) }, set: { speed = snapped(pow(2, $0)) }), in: -2...2)
                    .accessibilityLabel("Speed")
                    .accessibilityValue("\(VideoSpeedProcessor.label(speed)) times")
                HStack {
                    Text("0.25×")
                    Spacer()
                    Text("1×")
                    Spacer()
                    Text("4×")
                }
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(VideoSpeedProcessor.presets, id: \.self) { preset in
                        Button("\(VideoSpeedProcessor.label(preset))×") {
                            speed = preset
                            invalidEntry = false
                        }
                        .buttonStyle(VideoChipStyle(selected: abs(speed - preset) < 0.001))
                    }
                }
                VideoHint("Choose a speed between 0.25 and 4", warning: invalidEntry)
            }
            ToolSection("Audio") {
                ToolSegmented(selection: $keepAudio, options: [(true, "Keep Audio"), (false, "Mute")])
                    .disabled(!hasAudio)
                VideoHint(!hasAudio && !player.isLoading
                          ? "This video has no audio."
                          : keepAudio ? "Audio is sped up with its pitch kept natural." : "The copy will have no sound.")
            }
            ToolSection("Duration") {
                HStack(spacing: 8) {
                    Text(VideoText.time(player.duration))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(VideoText.time(player.duration / speed))
                        .fontWeight(.semibold)
                }
                .font(.system(size: 13).monospacedDigit())
            }
            Spacer(minLength: 0)
        }
    }

    /// Slider values snap to steps of 0.05.
    private func snapped(_ value: Double) -> Double {
        let step = (value * 20).rounded() / 20
        return min(VideoSpeedProcessor.range.upperBound, max(VideoSpeedProcessor.range.lowerBound, step))
    }

    private func setTyped(_ value: Double) {
        if VideoSpeedProcessor.range.contains(value) {
            invalidEntry = false
            speed = (value * 100).rounded() / 100
        } else {
            invalidEntry = true
            typedSpeed = speed
        }
    }

    private func save() {
        let speed = speed
        let keepAudio = keepAudio && hasAudio
        session.runPerItem { url, context in
            [try await VideoSpeedProcessor.change(url, speed: speed, keepAudio: keepAudio, context: context)]
        }
    }
}
