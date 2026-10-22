import SwiftUI

// MARK: - Processing

enum TrimVideoProcessor {
    enum Mode: String, CaseIterable {
        /// Re-encodes for frame-exact cuts.
        case accurate
        /// Copies the streams; cuts land on keyframes.
        case fast
    }

    /// Saves `start...end` of `source` beside it as "<name>-trimmed.<ext>".
    static func trim(_ source: URL, start: Double, end: Double, mode: Mode, context: JobContext) async throws -> URL {
        let info = try await VideoExport.probe(source)
        let lower = max(0, start)
        let upper = info.duration > 0 ? min(end, info.duration) : end
        guard upper - lower >= 0.04 else { throw ProcessError.failed("Choose a longer range to trim.") }
        let output = VideoExport.output(for: source, suffix: "-trimmed")
        var arguments = ["-ss", VideoExport.seconds(lower), "-i", source.path, "-t", VideoExport.seconds(upper - lower),
                         "-map", "0:V:0", "-map", "0:a?"]
        switch mode {
        case .accurate:
            arguments += ["-vf", VideoExport.evenSize] + FFmpegTool.videoCodecArguments(for: output)
            arguments += info.hasAudio ? FFmpegTool.audioCodecArguments(for: output) : ["-an"]
        case .fast:
            arguments += ["-c", "copy", "-avoid_negative_ts", "make_zero"]
        }
        arguments += ["-map_metadata", "0"] + VideoExport.containerArguments(for: output)
        try await VideoExport.run(arguments, output: output, duration: upper - lower, context: context)
        return output
    }
}

// MARK: - Editor

struct TrimVideoEditor: View {
    @ObservedObject var session: ToolSession
    @StateObject private var player = MediaPlayerModel()
    @State private var thumbnails: [CGImage] = []
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var mode: TrimVideoProcessor.Mode = .accurate

    private let minimumLength = 0.1
    private var url: URL { session.primaryURL }
    private var length: Double { max(0, end - start) }
    private var isTrimmed: Bool { start > 0.005 || end < player.duration - 0.005 }

    var body: some View {
        ToolScaffold(session: session, subtitle: VideoText.subtitle(url, player.info)) {
            VStack(alignment: .leading, spacing: 12) {
                VideoStage(player: player, source: url)
                    .frame(minHeight: 200)
                PlaybackBar(player: player) {
                    Button {
                        playSelection()
                    } label: {
                        Label("Play Selected Range", systemImage: "play.square")
                    }
                    .buttonStyle(VideoActionStyle(prominent: true))
                    .disabled(player.playableURL == nil || player.duration <= 0)
                    .help("Play only the part you are keeping")
                }
                VStack(alignment: .leading, spacing: 7) {
                    RangeTrack(start: $start, end: $end, duration: max(player.duration, 0.001), playhead: player.currentTime,
                               minimumLength: minimumLength,
                               onScrub: { time in
                                   player.playRange = nil
                                   player.seek(to: time)
                               }) {
                        ThumbnailStrip(images: thumbnails)
                    }
                    .frame(height: 56)
                    .padding(.vertical, 4)
                    .help("Play or pause the timeline preview (Space)")
                    .accessibilityLabel("Trim range. Drag the ends to trim.")
                    HStack {
                        VideoHint("Drag the ends to trim")
                        Spacer()
                        Text("Keeping \(VideoText.length(length))")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 14) {
                    SecondsField(title: "Start", seconds: $start, range: 0...max(0, end - minimumLength))
                    SecondsField(title: "End", seconds: $end,
                                 range: min(start + minimumLength, max(player.duration, 0))...max(player.duration, start + minimumLength))
                    Spacer(minLength: 8)
                    ToolSegmented(selection: $mode, options: [(.accurate, "Accurate"), (.fast, "Fast")])
                        .help("Accurate re-encodes for exact frames. Fast copies the video and cuts at keyframes.")
                }
                VideoHint(mode == .accurate
                          ? "Accurate cuts exactly at the frames you chose. It re-encodes the video."
                          : "Fast copies the original streams without re-encoding, so cuts land on the nearest keyframes.")
            }
            .padding(16)
            .background(VideoKeyMonitor { _ in false })
        } footer: {
            ToolFooter(session: session, primaryTitle: "Save Trimmed Copy",
                       primaryEnabled: player.duration > 0 && length >= minimumLength && isTrimmed,
                       action: save) {
                if player.duration > 0 {
                    Text("\(VideoText.time(player.duration)) → \(VideoText.time(length))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            thumbnails = await VideoEditorLoader.load(player, url: url)
            if end <= 0 { end = player.duration }
        }
        .onChange(of: start) { player.playRange = nil }
        .onChange(of: end) { player.playRange = nil }
    }

    private func playSelection() {
        player.playRange = start...end
        player.seek(to: start)
        player.play()
    }

    private func save() {
        let lower = start
        let upper = end
        let mode = mode
        session.runPerItem { url, context in
            [try await TrimVideoProcessor.trim(url, start: lower, end: upper, mode: mode, context: context)]
        }
    }
}
