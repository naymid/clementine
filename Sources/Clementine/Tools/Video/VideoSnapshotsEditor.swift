import SwiftUI

// MARK: - Processing

enum VideoSnapshotsProcessor {
    /// "-00m12s" (or "-1h02m03s" past an hour).
    static func suffix(for seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "-%dh%02dm%02ds", hours, minutes, secs)
            : String(format: "-%02dm%02ds", minutes, secs)
    }

    /// Saves a full-resolution, upright PNG of the frame shown at each time, e.g. "clip-00m12s.png".
    static func save(_ source: URL, times: [Double], context: JobContext) async throws -> [URL] {
        guard !times.isEmpty else { throw ProcessError.failed("Add a frame to save.") }
        let info = try await VideoExport.probe(source)
        let frameLength = 1 / VideoExport.frameRate(info)
        var outputs: [URL] = []
        for (index, time) in times.sorted().enumerated() {
            try context.checkCancelled()
            let clamped = info.duration > 0 ? min(time, max(0, info.duration - frameLength)) : time
            // ffmpeg keeps the first frame at or after the seek point; starting just under one
            // frame earlier returns the frame the player was showing at `time`.
            let seek = max(0, clamped - frameLength + 0.001)
            let output = FileNaming.output(beside: source, suffix: suffix(for: time), extension: "png")
            let arguments = ["-ss", VideoExport.seconds(seek), "-i", source.path, "-map", "0:V:0", "-frames:v", "1",
                             "-an", "-update", "1", "-c:v", "png"]
            do {
                try await VideoExport.run(arguments, output: output, duration: 0, context: context)
            } catch {
                outputs.forEach { try? FileManager.default.removeItem(at: $0) }
                throw error
            }
            guard FileManager.default.fileExists(atPath: output.path) else {
                outputs.forEach { try? FileManager.default.removeItem(at: $0) }
                throw ProcessError.failed("No frame could be read at \(VideoText.time(time)).")
            }
            outputs.append(output)
            context.progress(Double(index + 1) / Double(times.count))
        }
        return outputs
    }
}

// MARK: - Editor

struct VideoSnapshotsEditor: View {
    @ObservedObject var session: ToolSession
    /// Optional starting frames, used by design snapshots.
    var initialTimes: [Double] = []

    struct Frame: Identifiable, Equatable {
        let id = UUID()
        var time: Double
        var image: CGImage?
        static func == (a: Frame, b: Frame) -> Bool { a.id == b.id && a.time == b.time && (a.image == nil) == (b.image == nil) }
    }

    @StateObject private var player = MediaPlayerModel()
    @State private var thumbnails: [CGImage] = []
    @State private var frames: [Frame] = []
    @State private var selectedID: UUID?
    @State private var showingPreview = false
    @State private var previewImage: CGImage?

    private var url: URL { session.primaryURL }
    private var selected: Frame? { frames.first { $0.id == selectedID } }
    private var frameLength: Double { 1 / VideoExport.frameRate(player.info) }
    private var saveTitle: String {
        switch frames.count {
        case 0: return "Save Snapshots"
        case 1: return "Save 1 Snapshot"
        default: return "Save \(frames.count) Snapshots"
        }
    }

    var body: some View {
        ToolScaffold(session: session, subtitle: VideoText.subtitle(url, player.info)) {
            VStack(alignment: .leading, spacing: 12) {
                VideoStage(player: player, source: url)
                    .frame(minHeight: 200)
                PlaybackBar(player: player) {
                    Button(action: addFrame) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.viewfinder")
                            Text("Add Frame")
                            Text("⏎").font(.system(size: 11)).opacity(0.7)
                        }
                    }
                    .buttonStyle(VideoActionStyle(prominent: true))
                    .disabled(player.duration <= 0)
                    .help("Add the frame at the playhead (Return)")
                }
                VideoThumbnailTimeline(thumbnails: thumbnails, duration: max(player.duration, 0.001), playhead: player.currentTime,
                                       onScrub: { player.seek(to: $0) }) { metrics, height in
                    ForEach(frames) { frame in
                        VStack(spacing: 0) {
                            SnapshotMarkerHead()
                                .fill(frame.id == selectedID ? Brand.buttonOrange : Color.white)
                                .frame(width: 9, height: 6)
                            Rectangle()
                                .fill(frame.id == selectedID ? Brand.buttonOrange : Color.white.opacity(0.8))
                                .frame(width: 2, height: height - 6)
                        }
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .offset(x: metrics.x(frame.time) - 4.5)
                        .allowsHitTesting(false)
                    }
                }
                .frame(height: 44)
                .padding(.vertical, 4)
                framesStrip
            }
            .padding(16)
            .background(VideoKeyMonitor(handler: handleKey))
        } footer: {
            ToolFooter(session: session, primaryTitle: saveTitle, primaryEnabled: !frames.isEmpty, action: save) {
                Text(verbatim: player.info.hasVideo ? "Full size PNG · \(VideoText.size(player.info.displaySize))" : "")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            thumbnails = await VideoEditorLoader.load(player, url: url)
            for time in initialTimes { await add(at: time) }
        }
    }

    // MARK: Frames strip

    private var framesStrip: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                if frames.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 18, weight: .light))
                        Text("Add a frame to save.")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ScrollViewReader { reader in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(frames) { frame in
                                    card(frame).id(frame.id)
                                }
                            }
                            .padding(8)
                        }
                        .onChange(of: selectedID) {
                            if let selectedID { withAnimation { reader.scrollTo(selectedID, anchor: .center) } }
                        }
                    }
                }
            }
            .frame(height: 96)
            VStack(spacing: 8) {
                Button {
                    openPreview()
                } label: {
                    Image(systemName: "eye")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(VideoActionStyle())
                .disabled(selected == nil)
                .help("Preview selected frame")
                .accessibilityLabel("Preview selected frame")
                .popover(isPresented: $showingPreview, arrowEdge: .leading) { previewPopover }
                Button {
                    removeSelected()
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(VideoActionStyle())
                .disabled(selected == nil)
                .help("Remove selected frame (Delete)")
                .accessibilityLabel("Remove selected frame")
            }
        }
    }

    private func card(_ frame: Frame) -> some View {
        let isSelected = frame.id == selectedID
        return VStack(spacing: 4) {
            ZStack {
                Color.black
                if let image = frame.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Brand.buttonOrange : Color.primary.opacity(0.12), lineWidth: isSelected ? 2.5 : 1))
            Text(VideoText.time(frame.time))
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isSelected ? AnyShapeStyle(Brand.buttonOrange) : AnyShapeStyle(.secondary))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedID = frame.id
            player.pause()
            player.seek(to: frame.time)
        }
        .contextMenu {
            Button("Preview Frame") {
                selectedID = frame.id
                openPreview()
            }
            Button("Remove Frame") {
                selectedID = frame.id
                removeSelected()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Frame at \(VideoText.time(frame.time))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var previewPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                if let previewImage {
                    Image(decorative: previewImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 420, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if let selected {
                Text("Frame at \(VideoText.time(selected.time))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
        .padding(12)
    }

    // MARK: Actions

    private func addFrame() {
        player.pause()
        Task { await add(at: player.currentTime) }
    }

    private func add(at time: Double) async {
        guard player.duration > 0 else { return }
        let time = max(0, min(time, player.duration))
        if let existing = frames.first(where: { abs($0.time - time) < frameLength / 2 }) {
            selectedID = existing.id
            return
        }
        let frame = Frame(time: time)
        let index = frames.firstIndex { $0.time > time } ?? frames.count
        frames.insert(frame, at: index)
        selectedID = frame.id
        let image = await VideoFrames.frame(source: url, playable: player.playableURL,
                                            at: min(time, max(0, player.duration - frameLength)), maxSize: 240)
        if let position = frames.firstIndex(where: { $0.id == frame.id }) { frames[position].image = image }
    }

    private func removeSelected() {
        guard let index = frames.firstIndex(where: { $0.id == selectedID }) else { return }
        frames.remove(at: index)
        selectedID = frames.isEmpty ? nil : frames[min(index, frames.count - 1)].id
    }

    private func openPreview() {
        guard let selected else { return }
        previewImage = nil
        showingPreview = true
        Task {
            let image = await VideoFrames.frame(source: url, playable: player.playableURL,
                                                at: min(selected.time, max(0, player.duration - frameLength)), maxSize: 960)
            previewImage = image
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if VideoKeyMonitor.returnKeys.contains(event.keyCode) {
            if player.duration > 0 { addFrame() }
            return true
        }
        if VideoKeyMonitor.deleteKeys.contains(event.keyCode), selected != nil {
            removeSelected()
            return true
        }
        return false
    }

    private func save() {
        let times = frames.map(\.time)
        session.runPerItem(successTitle: { $0.count == 1 ? "Saved snapshot" : "Saved \($0.count) snapshots" }) { url, context in
            try await VideoSnapshotsProcessor.save(url, times: times, context: context)
        }
    }
}

/// A small downward-pointing marker head.
private struct SnapshotMarkerHead: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
