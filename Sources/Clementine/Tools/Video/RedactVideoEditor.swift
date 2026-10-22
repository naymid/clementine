import SwiftUI

// MARK: - Processing

struct VideoRedaction: Identifiable, Equatable {
    var id = UUID()
    /// Area in display pixels (after rotation).
    var rect: CGRect
    var start: Double
    var end: Double

    func isShown(at time: Double) -> Bool { time >= start && time <= end }
}

enum RedactVideoProcessor {
    enum Style: String, CaseIterable {
        case solid, blur
    }

    struct Box: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    /// Even-aligned pixel box inside the frame, so chroma planes line up.
    static func box(_ rect: CGRect, in size: CGSize) -> Box? {
        let frameWidth = Int(size.width) / 2 * 2
        let frameHeight = Int(size.height) / 2 * 2
        var x = max(0, Int(rect.minX.rounded(.down))) / 2 * 2
        var y = max(0, Int(rect.minY.rounded(.down))) / 2 * 2
        var maxX = min(frameWidth, (Int(rect.maxX.rounded(.up)) + 1) / 2 * 2)
        var maxY = min(frameHeight, (Int(rect.maxY.rounded(.up)) + 1) / 2 * 2)
        x = min(x, frameWidth - 2)
        y = min(y, frameHeight - 2)
        maxX = max(maxX, x + 2)
        maxY = max(maxY, y + 2)
        guard frameWidth >= 2, frameHeight >= 2 else { return nil }
        return Box(x: x, y: y, width: maxX - x, height: maxY - y)
    }

    /// The video filter graph, reading [0:v] and writing [v].
    static func filterGraph(_ redactions: [VideoRedaction], style: Style, size: CGSize) -> String {
        let items = redactions.compactMap { redaction -> (Box, String)? in
            guard let box = box(redaction.rect, in: size) else { return nil }
            let enable = "enable='between(t,\(VideoExport.seconds(redaction.start)),\(VideoExport.seconds(redaction.end)))'"
            return (box, enable)
        }
        guard !items.isEmpty else { return "[0:v]\(VideoExport.evenSize)[v]" }
        switch style {
        case .solid:
            let boxes = items.map { box, enable in
                "drawbox=x=\(box.x):y=\(box.y):w=\(box.width):h=\(box.height):color=black@1:t=fill:\(enable)"
            }
            return "[0:v]" + boxes.joined(separator: ",") + ",\(VideoExport.evenSize)[v]"
        case .blur:
            var parts: [String] = []
            let labels = items.indices.map { "[c\($0)]" }.joined()
            parts.append("[0:v]split=\(items.count + 1)[base]\(labels)")
            for (index, item) in items.enumerated() {
                let box = item.0
                let side = min(box.width, box.height)
                let luma = max(1, min(40, side / 2 - 1))
                let chroma = max(1, min(20, side / 4 - 1))
                parts.append("[c\(index)]crop=\(box.width):\(box.height):\(box.x):\(box.y),boxblur=luma_radius=\(luma):luma_power=4:chroma_radius=\(chroma):chroma_power=4[b\(index)]")
            }
            var previous = "[base]"
            for (index, item) in items.enumerated() {
                let box = item.0
                let next = index == items.count - 1 ? "[o]" : "[o\(index)]"
                parts.append("\(previous)[b\(index)]overlay=x=\(box.x):y=\(box.y):\(item.1)\(next)")
                previous = next
            }
            parts.append("[o]\(VideoExport.evenSize)[v]")
            return parts.joined(separator: ";")
        }
    }

    /// Covers each area during its time range and saves "<name>-redacted.<ext>".
    static func redact(_ source: URL, redactions: [VideoRedaction], style: Style, context: JobContext) async throws -> URL {
        guard !redactions.isEmpty else { throw ProcessError.failed("Draw a rectangle to redact.") }
        let info = try await VideoExport.probe(source)
        let output = VideoExport.output(for: source, suffix: "-redacted")
        var arguments = ["-i", source.path, "-filter_complex", filterGraph(redactions, style: style, size: info.displaySize),
                         "-map", "[v]", "-map", "0:a?"]
        arguments += FFmpegTool.videoCodecArguments(for: output)
        arguments += info.hasAudio ? ["-c:a", "copy"] : ["-an"]
        arguments += ["-map_metadata", "0"] + VideoExport.containerArguments(for: output)
        try await VideoExport.run(arguments, output: output, duration: info.duration, context: context)
        return output
    }
}

// MARK: - Editor

struct RedactVideoEditor: View {
    @ObservedObject var session: ToolSession
    /// Optional starting redactions (as fractions of the frame), used by design snapshots.
    var initialAreas: [(rect: CGRect, start: Double, end: Double)] = []

    @StateObject private var player = MediaPlayerModel()
    @State private var thumbnails: [CGImage] = []
    @State private var redactions: [VideoRedaction] = []
    @State private var selectedID: UUID?
    @State private var drawingID: UUID?
    @State private var style: RedactVideoProcessor.Style = .solid
    @State private var laneDrag: (id: UUID, start: Double, end: Double)?

    private var url: URL { session.primaryURL }
    private var frameSize: CGSize { player.info.displaySize }
    private var selectedIndex: Int? { redactions.firstIndex { $0.id == selectedID } }

    var body: some View {
        ToolScaffold(session: session, subtitle: VideoText.subtitle(url, player.info)) {
            VStack(alignment: .leading, spacing: 10) {
                VideoStage(player: player, source: url) { videoRect in
                    redactionOverlay(videoRect)
                }
                .frame(minHeight: 220)
                PlaybackBar(player: player) {
                    if let index = selectedIndex {
                        Text("Redaction \(index + 1): \(VideoText.time(redactions[index].start)) – \(VideoText.time(redactions[index].end))")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 6) {
                    VideoThumbnailTimeline(thumbnails: thumbnails, duration: max(player.duration, 0.001), playhead: player.currentTime,
                                           onScrub: { player.seek(to: $0) })
                        .frame(height: 40)
                    lanes
                }
                .padding(.vertical, 4)
                controls
            }
            .padding(16)
            .background(VideoKeyMonitor(handler: handleKey))
        } footer: {
            ToolFooter(session: session, primaryTitle: "Save Redacted Copy", primaryEnabled: !redactions.isEmpty && frameSize.width > 0,
                       action: save) {
                Text(redactions.isEmpty ? "No redactions" : redactions.count == 1 ? "1 redaction" : "\(redactions.count) redactions")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            thumbnails = await VideoEditorLoader.load(player, url: url)
            let size = frameSize
            for area in initialAreas {
                redactions.append(VideoRedaction(rect: CGRect(x: area.rect.minX * size.width, y: area.rect.minY * size.height,
                                                              width: area.rect.width * size.width, height: area.rect.height * size.height),
                                                 start: area.start, end: min(area.end, player.duration)))
            }
            selectedID = redactions.first?.id
        }
    }

    // MARK: Video overlay

    @ViewBuilder
    private func redactionOverlay(_ videoRect: CGRect) -> some View {
        if frameSize.width > 0 {
            let mapping = VideoPixelMapping(frameSize: frameSize, videoRect: videoRect)
            ZStack(alignment: .topLeading) {
                VideoRectDrawLayer(mapping: mapping, ratio: nil, onDraw: draw, onEnd: finishDrawing, onTap: { selectedID = nil })
                ForEach(redactions) { redaction in
                    let shown = redaction.isShown(at: player.currentTime)
                    let frame = mapping.viewRect(redaction.rect)
                    if shown {
                        cover(selected: redaction.id == selectedID)
                            .frame(width: max(1, frame.width), height: max(1, frame.height))
                            .contentShape(Rectangle())
                            .onTapGesture { selectedID = redaction.id }
                            .position(x: frame.midX, y: frame.midY)
                    } else if redaction.id == selectedID {
                        Rectangle()
                            .strokeBorder(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .frame(width: max(1, frame.width), height: max(1, frame.height))
                            .position(x: frame.midX, y: frame.midY)
                            .allowsHitTesting(false)
                    }
                }
                if let index = selectedIndex, drawingID == nil {
                    VideoRectEditor(rect: redactions[index].rect, mapping: mapping, ratio: nil, minimumSize: 8, tint: Brand.buttonOrange,
                                    accessibilityText: "Redaction \(index + 1). Drag to reposition.") { rect in
                        if let current = selectedIndex { redactions[current].rect = rect }
                    }
                }
                if redactions.isEmpty && !player.isLoading {
                    VStack {
                        VideoBanner(text: "Draw rectangles to cover areas.", symbol: "rectangle.dashed")
                            .padding(10)
                        Spacer()
                    }
                    .frame(width: videoRect.width + videoRect.minX * 2)
                    .allowsHitTesting(false)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Redaction preview. Draw rectangles to cover areas.")
        }
    }

    /// The preview of a redaction while it is on screen. The faint outline keeps
    /// solid boxes findable over dark video.
    @ViewBuilder
    private func cover(selected: Bool) -> some View {
        Group {
            switch style {
            case .solid:
                Rectangle().fill(Color.black)
            case .blur:
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(VideoStripes(spacing: 9).stroke(Color.white.opacity(0.12), lineWidth: 1).clipped())
                    .environment(\.colorScheme, .light)
            }
        }
        .overlay(Rectangle().strokeBorder(Color.white.opacity(selected ? 0 : 0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    // MARK: Lanes

    private var lanes: some View {
        let laneHeight: CGFloat = 20
        return ScrollView(.vertical, showsIndicators: redactions.count > 4) {
            VStack(spacing: 4) {
                if redactions.isEmpty {
                    Text("Each redaction gets a lane here showing when it is on screen.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: laneHeight)
                } else {
                    ForEach(Array(redactions.enumerated()), id: \.element.id) { index, redaction in
                        lane(index: index, redaction: redaction)
                            .frame(height: laneHeight)
                    }
                }
            }
        }
        .frame(height: min(CGFloat(max(redactions.count, 1)), 4) * (laneHeight + 4))
    }

    private func lane(index: Int, redaction: VideoRedaction) -> some View {
        let isSelected = redaction.id == selectedID
        return GeometryReader { proxy in
            let metrics = VideoTimelineMetrics(width: proxy.size.width, duration: max(player.duration, 0.001))
            let x = metrics.x(redaction.start)
            let width = max(10, metrics.x(redaction.end) - x)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: metrics.usable, height: proxy.size.height)
                    .offset(x: metrics.inset)
                    .onTapGesture { selectedID = redaction.id }
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Brand.buttonOrange : Color.primary.opacity(0.28))
                    .overlay(alignment: .leading) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.leading, 12)
                    }
                    .frame(width: width, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in moveLane(redaction, by: Double(value.translation.width) * metrics.secondsPerPoint) }
                        .onEnded { _ in laneDrag = nil })
                    .simultaneousGesture(TapGesture().onEnded { selectedID = redaction.id })
                    .offset(x: x)
                laneGrip(redaction, edge: .leading, metrics: metrics, height: proxy.size.height, selected: isSelected)
                    .offset(x: x - 1)
                laneGrip(redaction, edge: .trailing, metrics: metrics, height: proxy.size.height, selected: isSelected)
                    .offset(x: x + width - 9)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Redaction \(index + 1), shown from \(VideoText.time(redaction.start)) to \(VideoText.time(redaction.end))")
    }

    private func laneGrip(_ redaction: VideoRedaction, edge: HorizontalEdge, metrics: VideoTimelineMetrics,
                          height: CGFloat, selected: Bool) -> some View {
        Capsule()
            .fill(Color.white.opacity(selected ? 0.95 : 0.7))
            .frame(width: 3, height: height * 0.55)
            .frame(width: 10, height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let origin = laneDrag?.id == redaction.id ? laneDrag! : (redaction.id, redaction.start, redaction.end)
                    if laneDrag == nil { laneDrag = origin; selectedID = redaction.id }
                    let delta = Double(value.translation.width) * metrics.secondsPerPoint
                    guard let index = redactions.firstIndex(where: { $0.id == redaction.id }) else { return }
                    if edge == .leading {
                        redactions[index].start = max(0, min(origin.end - 0.1, origin.start + delta))
                        player.seek(to: redactions[index].start)
                    } else {
                        redactions[index].end = min(player.duration, max(origin.start + 0.1, origin.end + delta))
                        player.seek(to: redactions[index].end)
                    }
                }
                .onEnded { _ in laneDrag = nil })
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .help(edge == .leading ? "Drag to change when this redaction starts" : "Drag to change when this redaction ends")
    }

    private func moveLane(_ redaction: VideoRedaction, by delta: Double) {
        let origin = laneDrag?.id == redaction.id ? laneDrag! : (redaction.id, redaction.start, redaction.end)
        if laneDrag == nil { laneDrag = origin; selectedID = redaction.id }
        guard let index = redactions.firstIndex(where: { $0.id == redaction.id }) else { return }
        let length = origin.end - origin.start
        let start = max(0, min(player.duration - length, origin.start + delta))
        redactions[index].start = start
        redactions[index].end = start + length
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: addAtPlayhead) {
                    Label("Add Redaction at Playhead", systemImage: "plus.rectangle")
                }
                .buttonStyle(VideoActionStyle(prominent: true))
                .disabled(frameSize.width <= 0)
                Button {
                    if let index = selectedIndex {
                        redactions[index].start = 0
                        redactions[index].end = player.duration
                    }
                } label: {
                    Label("Show for Entire Video", systemImage: "arrow.left.and.right")
                }
                .buttonStyle(VideoActionStyle())
                .disabled(selectedIndex == nil)
                Button(action: deleteSelected) {
                    Label("Delete Redaction", systemImage: "trash")
                }
                .buttonStyle(VideoActionStyle())
                .disabled(selectedIndex == nil)
                .help("Delete the selected redaction (Delete)")
                Spacer(minLength: 8)
                ToolSegmented(selection: $style, options: [(.solid, "Solid"), (.blur, "Blur")])
            }
            HStack {
                VideoHint("Drag over the video to cover an area. Drag the ends of a lane to set when it shows.")
                Spacer(minLength: 8)
                VideoHint("Blur softens details. Use Solid for sensitive information.", warning: style == .blur)
            }
        }
    }

    // MARK: Actions

    private func draw(_ rect: CGRect) {
        guard rect.width >= 2, rect.height >= 2 else { return }
        if let drawingID, let index = redactions.firstIndex(where: { $0.id == drawingID }) {
            redactions[index].rect = rect
        } else {
            let redaction = VideoRedaction(rect: rect, start: player.currentTime, end: player.duration)
            redactions.append(redaction)
            drawingID = redaction.id
            selectedID = redaction.id
        }
    }

    private func finishDrawing() {
        if let drawingID, let index = redactions.firstIndex(where: { $0.id == drawingID }) {
            let rect = redactions[index].rect
            if rect.width < 6 || rect.height < 6 {
                redactions.remove(at: index)
                selectedID = nil
            }
        }
        drawingID = nil
    }

    private func addAtPlayhead() {
        guard frameSize.width > 0 else { return }
        let width = frameSize.width * 0.3
        let height = frameSize.height * 0.3
        let offset = CGFloat(redactions.count % 5) * frameSize.width * 0.03
        let rect = CGRect(x: (frameSize.width - width) / 2 + offset, y: (frameSize.height - height) / 2 + offset, width: width, height: height)
        let redaction = VideoRedaction(rect: VideoRectMath.moved(rect, by: .zero, within: CGRect(origin: .zero, size: frameSize)),
                                       start: min(player.currentTime, max(0, player.duration - 0.1)), end: player.duration)
        redactions.append(redaction)
        selectedID = redaction.id
    }

    private func deleteSelected() {
        guard let index = selectedIndex else { return }
        redactions.remove(at: index)
        selectedID = redactions.isEmpty ? nil : redactions[min(index, redactions.count - 1)].id
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if VideoKeyMonitor.deleteKeys.contains(event.keyCode), selectedIndex != nil {
            deleteSelected()
            return true
        }
        if VideoKeyMonitor.arrowKeys.contains(event.keyCode), let index = selectedIndex {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta: CGSize
            switch event.keyCode {
            case 123: delta = CGSize(width: -step, height: 0)
            case 124: delta = CGSize(width: step, height: 0)
            case 125: delta = CGSize(width: 0, height: step)
            default: delta = CGSize(width: 0, height: -step)
            }
            redactions[index].rect = VideoRectMath.moved(redactions[index].rect, by: delta, within: CGRect(origin: .zero, size: frameSize))
            return true
        }
        return false
    }

    private func save() {
        let redactions = redactions
        let style = style
        session.runPerItem { url, context in
            [try await RedactVideoProcessor.redact(url, redactions: redactions, style: style, context: context)]
        }
    }
}
