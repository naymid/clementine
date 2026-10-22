import SwiftUI

// MARK: - Model

/// Split points across a video and which of the resulting clips are removed.
struct VideoSplitPlan: Equatable {
    static let minimumGap = 0.05

    struct Clip: Identifiable, Equatable {
        /// 1-based position in the timeline.
        var number: Int
        var start: Double
        var end: Double
        var removed: Bool
        var id: Int { number }
        var length: Double { end - start }
    }

    private(set) var duration: Double
    private(set) var points: [Double] = []
    private(set) var removed: [Bool] = [false]

    init(duration: Double) {
        self.duration = duration
    }

    var clips: [Clip] {
        let edges = [0] + points + [duration]
        return (0..<(edges.count - 1)).map {
            Clip(number: $0 + 1, start: edges[$0], end: edges[$0 + 1], removed: removed[$0])
        }
    }

    var keptClips: [Clip] { clips.filter { !$0.removed } }
    var removedCount: Int { removed.filter { $0 }.count }

    /// Adds a split; false when it would be closer than 0.05 s to another split or an end.
    @discardableResult
    mutating func addSplit(at time: Double) -> Bool {
        let edges = [0] + points + [duration]
        guard time > 0, time < duration, edges.allSatisfy({ abs($0 - time) >= Self.minimumGap }) else { return false }
        let index = points.firstIndex { $0 > time } ?? points.count
        points.insert(time, at: index)
        removed.insert(removed[index], at: index + 1)
        return true
    }

    /// Removes split `index`, merging its two clips. The merged clip stays only if both were removed.
    mutating func removeSplit(at index: Int) {
        guard points.indices.contains(index) else { return }
        points.remove(at: index)
        let merged = removed[index] && removed[index + 1]
        removed.remove(at: index + 1)
        removed[index] = merged
    }

    /// Moves split `index`, keeping 0.05 s from its neighbours.
    mutating func moveSplit(_ index: Int, to time: Double) {
        guard points.indices.contains(index) else { return }
        let lower = (index > 0 ? points[index - 1] : 0) + Self.minimumGap
        let upper = (index < points.count - 1 ? points[index + 1] : duration) - Self.minimumGap
        guard lower <= upper else { return }
        points[index] = max(lower, min(upper, time))
    }

    mutating func setRemoved(_ value: Bool, clip offset: Int) {
        guard removed.indices.contains(offset) else { return }
        removed[offset] = value
    }

    mutating func restoreAll() {
        removed = Array(repeating: false, count: removed.count)
    }

    /// The 0-based clip containing `time`.
    func clipOffset(at time: Double) -> Int {
        points.firstIndex { time < $0 } ?? points.count
    }

    /// While playing through a removed clip: where to continue, or `duration` to stop. Nil when the clip is kept.
    func skipTarget(from time: Double) -> Double? {
        let all = clips
        let current = all[clipOffset(at: time)]
        guard current.removed else { return nil }
        if let next = all.first(where: { !$0.removed && $0.start >= current.end - 0.0001 }) { return next.start }
        return duration
    }
}

// MARK: - Processing

enum SplitVideoProcessor {
    enum Mode: String, CaseIterable {
        /// One file per kept clip, "<name>-part-N".
        case separate
        /// The kept clips joined, "<name>-edited".
        case oneVideo
    }

    /// Saves each clip as its own file, numbered by its position in the timeline.
    static func exportClips(_ source: URL, clips: [VideoSplitPlan.Clip], context: JobContext) async throws -> [URL] {
        let info = try await VideoExport.probe(source)
        let total = max(clips.reduce(0) { $0 + $1.length }, 0.001)
        var done = 0.0
        var outputs: [URL] = []
        for clip in clips {
            try context.checkCancelled()
            let output = VideoExport.output(for: source, suffix: "-part-\(clip.number)")
            var arguments = ["-ss", VideoExport.seconds(clip.start), "-i", source.path, "-t", VideoExport.seconds(clip.length),
                             "-map", "0:V:0", "-map", "0:a?", "-vf", VideoExport.evenSize]
            arguments += FFmpegTool.videoCodecArguments(for: output)
            arguments += info.hasAudio ? FFmpegTool.audioCodecArguments(for: output) : ["-an"]
            arguments += ["-map_metadata", "0"] + VideoExport.containerArguments(for: output)
            let range = (done / total)...((done + clip.length) / total)
            do {
                try await VideoExport.run(arguments, output: output, duration: clip.length, context: context, progress: range)
            } catch {
                outputs.forEach { try? FileManager.default.removeItem(at: $0) }
                throw error
            }
            outputs.append(output)
            done += clip.length
        }
        return outputs
    }

    /// Joins the clips, in order, into "<name>-edited.<ext>".
    static func exportJoined(_ source: URL, clips: [VideoSplitPlan.Clip], context: JobContext) async throws -> URL {
        guard !clips.isEmpty else { throw ProcessError.failed("Keep at least one clip.") }
        let info = try await VideoExport.probe(source)
        let output = VideoExport.output(for: source, suffix: "-edited")
        var arguments: [String] = []
        for clip in clips {
            arguments += ["-ss", VideoExport.seconds(clip.start), "-t", VideoExport.seconds(clip.length), "-i", source.path]
        }
        let inputs = clips.indices.map { index in info.hasAudio ? "[\(index):v:0][\(index):a:0]" : "[\(index):v:0]" }.joined()
        let concat = "\(inputs)concat=n=\(clips.count):v=1:a=\(info.hasAudio ? 1 : 0)\(info.hasAudio ? "[cv][a]" : "[cv]");[cv]\(VideoExport.evenSize)[v]"
        arguments += ["-filter_complex", concat, "-map", "[v]"]
        if info.hasAudio { arguments += ["-map", "[a]"] }
        arguments += FFmpegTool.videoCodecArguments(for: output)
        arguments += info.hasAudio ? FFmpegTool.audioCodecArguments(for: output) : ["-an"]
        arguments += ["-map_metadata", "0"] + VideoExport.containerArguments(for: output)
        let total = clips.reduce(0) { $0 + $1.length }
        try await VideoExport.run(arguments, output: output, duration: total, context: context)
        return output
    }
}

// MARK: - Editor

struct SplitVideoEditor: View {
    @ObservedObject var session: ToolSession
    /// Optional starting state, used by design snapshots.
    var initialSplits: [Double] = []
    var initialRemoved: Set<Int> = []

    @StateObject private var player = MediaPlayerModel()
    @State private var thumbnails: [CGImage] = []
    @State private var plan = VideoSplitPlan(duration: 0)
    @State private var selectedClip: Int?
    @State private var mode: SplitVideoProcessor.Mode = .separate
    @State private var modeChosen = false
    @State private var warning: String?
    @State private var draggingSplit: (index: Int, origin: Double)?

    private var url: URL { session.primaryURL }
    private var clips: [VideoSplitPlan.Clip] { plan.clips }
    private var kept: [VideoSplitPlan.Clip] { plan.keptClips }

    var body: some View {
        ToolScaffold(session: session, subtitle: VideoText.subtitle(url, player.info)) {
            VStack(alignment: .leading, spacing: 12) {
                VideoStage(player: player, source: url) { _ in
                    if let selectedClip, clips.indices.contains(selectedClip), clips[selectedClip].removed,
                       plan.clipOffset(at: player.currentTime) == selectedClip {
                        VStack {
                            VideoBanner(text: "Removed clip. It is skipped when playing.", symbol: "eye.slash")
                                .padding(10)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 200)
                PlaybackBar(player: player) {
                    if let warning {
                        Text(warning)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Brand.buttonOrange)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                    Button(action: addSplit) {
                        Label("Add Split", systemImage: "scissors")
                    }
                    .buttonStyle(VideoActionStyle(prominent: true))
                    .disabled(player.duration <= 0)
                    .help("Add a split point at the playhead")
                }
                timeline
                    .frame(height: 64)
                    .padding(.vertical, 4)
                clipBar
                Divider().opacity(0.5)
                HStack(spacing: 12) {
                    ToolSegmented(selection: Binding(get: { mode }, set: { mode = $0; modeChosen = true }),
                                  options: [(.separate, "Separate Clips"), (.oneVideo, "One Video")])
                    VideoHint("Remove a clip to join the rest into one video, or export separate clips.")
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .background(VideoKeyMonitor(handler: handleKey))
        } footer: {
            ToolFooter(session: session, primaryTitle: primaryTitle, primaryEnabled: canExport, action: export) {
                Text(summary)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            thumbnails = await VideoEditorLoader.load(player, url: url, thumbnailCount: 14)
            var plan = VideoSplitPlan(duration: player.duration)
            for time in initialSplits { plan.addSplit(at: time) }
            for offset in initialRemoved { plan.setRemoved(true, clip: offset) }
            self.plan = plan
            if !initialRemoved.isEmpty { mode = .oneVideo }
            selectedClip = initialRemoved.sorted().first
        }
        .onChange(of: player.currentTime) { skipRemoved() }
        .onChange(of: player.isPlaying) { skipRemoved() }
    }

    // MARK: Timeline

    private var timeline: some View {
        VideoThumbnailTimeline(thumbnails: thumbnails, duration: max(player.duration, 0.001), playhead: player.currentTime,
                               onScrub: { player.seek(to: $0) },
                               onClick: { time in selectedClip = plan.clipOffset(at: time) }) { metrics, height in
            ZStack(alignment: .topLeading) {
                ForEach(Array(clips.enumerated()), id: \.element.id) { offset, clip in
                    clipView(clip, selected: selectedClip == offset, metrics: metrics, height: height)
                }
                ForEach(Array(plan.points.enumerated()), id: \.offset) { index, point in
                    splitMarker(index: index, time: point, metrics: metrics, height: height)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline. Click a clip in the timeline and press Delete to remove it.")
    }

    private func clipView(_ clip: VideoSplitPlan.Clip, selected: Bool, metrics: VideoTimelineMetrics, height: CGFloat) -> some View {
        let x = metrics.x(clip.start)
        let width = max(2, metrics.x(clip.end) - x)
        return ZStack(alignment: .topLeading) {
            if clip.removed {
                Rectangle().fill(Color.black.opacity(0.62))
                VideoStripes()
                    .stroke(Color.white.opacity(0.22), lineWidth: 1.5)
                    .clipped()
                if width > 26 {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: width, height: height)
                }
            }
            if width > 22 {
                Text("\(clip.number)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(selected ? Brand.buttonOrange : Color.black.opacity(0.55)))
                    .padding(4)
            }
            if selected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Brand.buttonOrange, lineWidth: 3)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: clip.number == 1 || clip.number == clips.count ? 6 : 2, style: .continuous))
        .offset(x: x)
        .allowsHitTesting(false)
    }

    private func splitMarker(index: Int, time: Double, metrics: VideoTimelineMetrics, height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: height)
                .shadow(color: .black.opacity(0.6), radius: 1)
            Circle()
                .fill(Brand.buttonOrange)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                .frame(width: 11, height: 11)
                .offset(y: -6)
        }
        .frame(width: 16, height: height)
        .contentShape(Rectangle())
        .offset(x: metrics.x(time) - 8)
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { value in
                let origin = draggingSplit?.origin ?? time
                if draggingSplit == nil { draggingSplit = (index, time) }
                plan.moveSplit(index, to: origin + Double(value.translation.width) * metrics.secondsPerPoint)
                player.seek(to: plan.points[index])
            }
            .onEnded { _ in draggingSplit = nil })
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .contextMenu {
            Button("Remove Split Point") { removeSplit(index) }
        }
        .help("Split at \(VideoText.time(time)). Drag to move, right-click to remove.")
    }

    // MARK: Clip bar

    private var clipBar: some View {
        HStack(spacing: 8) {
            if let selectedClip, clips.indices.contains(selectedClip) {
                let clip = clips[selectedClip]
                Text("Clip \(clip.number) of \(clips.count)")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(VideoText.time(clip.start)) – \(VideoText.time(clip.end)) · \(VideoText.length(clip.length))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    toggleRemoved(selectedClip)
                } label: {
                    Label(clip.removed ? "Restore Clip" : "Remove Clip", systemImage: clip.removed ? "arrow.uturn.backward" : "trash")
                }
                .buttonStyle(VideoActionStyle())
                .help(clip.removed ? "Put this clip back" : "Remove this clip (Delete)")
            } else {
                VideoHint("Click a clip in the timeline and press Delete to remove it. Space plays the result.")
            }
            Spacer(minLength: 8)
            if plan.removedCount > 0 {
                Button {
                    plan.restoreAll()
                } label: {
                    Label("Restore Removed", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(VideoActionStyle())
            }
        }
        .frame(minHeight: 24)
    }

    // MARK: Actions

    private func addSplit() {
        let time = player.currentTime
        if plan.addSplit(at: time) {
            selectedClip = plan.clipOffset(at: time)
            warning = nil
        } else {
            showWarning("Split points must be at least 0.05 seconds apart.")
        }
    }

    private func removeSplit(_ index: Int) {
        plan.removeSplit(at: index)
        if let selectedClip, selectedClip >= clips.count { self.selectedClip = clips.count - 1 }
    }

    private func toggleRemoved(_ offset: Int) {
        guard clips.indices.contains(offset) else { return }
        let removing = !clips[offset].removed
        if removing && kept.count <= 1 {
            showWarning("Keep at least one clip.")
            return
        }
        plan.setRemoved(removing, clip: offset)
        if removing && !modeChosen { mode = .oneVideo }
    }

    private func showWarning(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { warning = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            if warning == text { withAnimation(.easeOut(duration: 0.2)) { warning = nil } }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if VideoKeyMonitor.deleteKeys.contains(event.keyCode), let selectedClip {
            toggleRemoved(selectedClip)
            return true
        }
        return false
    }

    /// Playback jumps over removed clips, so Space plays the result.
    private func skipRemoved() {
        guard player.isPlaying, let target = plan.skipTarget(from: player.currentTime) else { return }
        if target >= player.duration - 0.01 {
            player.pause()
            player.seek(to: player.duration)
        } else {
            player.seek(to: target + 0.001)
        }
    }

    // MARK: Export

    private var canExport: Bool {
        guard player.duration > 0, !kept.isEmpty else { return false }
        switch mode {
        case .separate: return kept.count >= 2 || (plan.removedCount > 0 && !kept.isEmpty)
        case .oneVideo: return plan.removedCount > 0
        }
    }

    private var primaryTitle: String {
        switch mode {
        case .separate: return kept.count == 1 ? "Export 1 Clip" : "Export \(kept.count) Clips"
        case .oneVideo: return "Export One Video"
        }
    }

    private var summary: String {
        let total = kept.reduce(0) { $0 + $1.length }
        let removedText = plan.removedCount > 0 ? " · \(plan.removedCount) removed" : ""
        return "\(clips.count) \(clips.count == 1 ? "clip" : "clips")\(removedText) · \(VideoText.time(total))"
    }

    private func export() {
        let clips = kept
        switch mode {
        case .separate:
            session.runPerItem { url, context in
                try await SplitVideoProcessor.exportClips(url, clips: clips, context: context)
            }
        case .oneVideo:
            session.runPerItem { url, context in
                [try await SplitVideoProcessor.exportJoined(url, clips: clips, context: context)]
            }
        }
    }
}

/// Diagonal hatching for removed clips.
struct VideoStripes: Shape {
    var spacing: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}
