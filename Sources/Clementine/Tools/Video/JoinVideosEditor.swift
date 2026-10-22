import SwiftUI

// MARK: - Processing

enum JoinVideosProcessor {
    /// The output frame: the first video's upright size, rounded to even pixels.
    static func outputSize(for info: MediaInfo) -> (width: Int, height: Int) {
        let size = info.displaySize
        return (max(2, Int(size.width) / 2 * 2), max(2, Int(size.height) / 2 * 2))
    }

    /// Joins the videos in order into "<first>-joined.<ext of first>". Every video is scaled to fit
    /// the first one's frame (letterboxed), set to its frame rate, and videos without audio get silence.
    static func join(_ sources: [URL], context: JobContext) async throws -> URL {
        guard sources.count >= 2, let first = sources.first else { throw ProcessError.failed("Choose at least two videos to join.") }
        var infos: [MediaInfo] = []
        for source in sources { infos.append(try await VideoExport.probe(source)) }
        let (width, height) = outputSize(for: infos[0])
        let fps = VideoExport.number(VideoExport.frameRate(infos[0]))
        let withAudio = infos.contains { $0.hasAudio }
        let output = VideoExport.output(for: first, suffix: "-joined")

        var arguments: [String] = []
        for source in sources { arguments += ["-i", source.path] }
        var graph: [String] = []
        var concatInputs = ""
        for (index, info) in infos.enumerated() {
            graph.append("[\(index):v:0]scale=\(width):\(height):force_original_aspect_ratio=decrease,"
                + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=\(fps),format=yuv420p[v\(index)]")
            if withAudio {
                if info.hasAudio {
                    graph.append("[\(index):a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a\(index)]")
                } else {
                    graph.append("anullsrc=channel_layout=stereo:sample_rate=48000,atrim=duration=\(VideoExport.seconds(info.duration)),"
                        + "aformat=sample_fmts=fltp:channel_layouts=stereo[a\(index)]")
                }
                concatInputs += "[v\(index)][a\(index)]"
            } else {
                concatInputs += "[v\(index)]"
            }
        }
        graph.append("\(concatInputs)concat=n=\(sources.count):v=1:a=\(withAudio ? 1 : 0)\(withAudio ? "[v][a]" : "[v]")")
        arguments += ["-filter_complex", graph.joined(separator: ";"), "-map", "[v]"]
        if withAudio { arguments += ["-map", "[a]"] }
        arguments += FFmpegTool.videoCodecArguments(for: output)
        arguments += withAudio ? FFmpegTool.audioCodecArguments(for: output) : ["-an"]
        arguments += VideoExport.containerArguments(for: output)
        let total = infos.reduce(0) { $0 + $1.duration }
        try await VideoExport.run(arguments, output: output, duration: total, context: context)
        return output
    }

    /// Finder's name order.
    static func sortedByName(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

// MARK: - Editor

struct JoinVideosEditor: View {
    @ObservedObject var session: ToolSession

    struct Item: Identifiable, Equatable {
        let url: URL
        var info: MediaInfo?
        var thumbnail: CGImage?
        var bytes: Int64 = 0
        var id: URL { url }

        static func == (a: Item, b: Item) -> Bool {
            a.url == b.url && a.info?.duration == b.info?.duration && (a.thumbnail == nil) == (b.thumbnail == nil)
        }
    }

    @State private var items: [Item]
    @State private var selection: URL?

    init(session: ToolSession) {
        self.session = session
        _items = State(initialValue: session.urls.map { Item(url: $0, bytes: FileNaming.size(of: $0)) })
    }

    private var first: MediaInfo? { items.first?.info }
    private var loaded: Bool { items.allSatisfy { $0.info != nil } }
    private var totalDuration: Double { items.reduce(0) { $0 + ($1.info?.duration ?? 0) } }
    private var mismatchedSize: Bool {
        guard let first else { return false }
        return items.dropFirst().contains { item in
            guard let info = item.info else { return false }
            return info.displaySize != first.displaySize
        }
    }
    private var missingAudio: Bool {
        loaded && items.contains { $0.info?.hasAudio == true } && items.contains { $0.info?.hasAudio == false }
    }

    var body: some View {
        ToolScaffold(session: session, subtitle: "\(items.count) videos") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Order")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    VideoHint("Drag to reorder. The first video sets the size.")
                    Spacer(minLength: 8)
                    Button {
                        let order = JoinVideosProcessor.sortedByName(items.map(\.url))
                        withAnimation { items.sort { order.firstIndex(of: $0.url)! < order.firstIndex(of: $1.url)! } }
                    } label: {
                        Label("Sort by Name", systemImage: "textformat.abc")
                    }
                    .buttonStyle(VideoActionStyle())
                    .help("Order the files by name, as Finder lists them")
                    Button {
                        withAnimation { items.reverse() }
                    } label: {
                        Label("Reverse", systemImage: "arrow.up.arrow.down")
                    }
                    .buttonStyle(VideoActionStyle())
                    .help("Reverse the order")
                }
                List(selection: $selection) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(index: index, item: item)
                            .tag(item.url)
                            .listRowSeparator(.hidden)
                            .contextMenu { contextMenu(for: index) }
                    }
                    .onMove { offsets, destination in
                        items.move(fromOffsets: offsets, toOffset: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                summary
            }
            .padding(16)
        } footer: {
            ToolFooter(session: session, primaryTitle: "Join Videos", primaryEnabled: items.count >= 2, action: join) {
                Text(loaded ? "Total \(VideoText.time(totalDuration))" : "Reading videos…")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .task { await load() }
    }

    private func row(index: Int, item: Item) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(index == 0 ? AnyShapeStyle(Brand.buttonOrange) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            ZStack {
                Color.black
                if let thumbnail = item.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "film").foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 72, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details(for: item))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if index == 0 {
                Text("Sets size")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Brand.buttonOrange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Brand.buttonOrange.opacity(0.12)))
            }
            VStack(spacing: 0) {
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up").frame(width: 18, height: 14) }
                    .disabled(index == 0)
                    .help("Move up")
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down").frame(width: 18, height: 14) }
                    .disabled(index == items.count - 1)
                    .help("Move down")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(index + 1). \(item.url.lastPathComponent), \(details(for: item))")
    }

    @ViewBuilder
    private func contextMenu(for index: Int) -> some View {
        Button("Move to Top") { move(index, to: 0) }.disabled(index == 0)
        Button("Move Up") { move(index, by: -1) }.disabled(index == 0)
        Button("Move Down") { move(index, by: 1) }.disabled(index == items.count - 1)
        Button("Move to Bottom") { move(index, to: items.count - 1) }.disabled(index == items.count - 1)
        if items.count > 2 {
            Divider()
            Button("Leave Out of Join") { withAnimation { _ = items.remove(at: index) } }
        }
    }

    private var summary: some View {
        ToolSection {
            if let first {
                let size = JoinVideosProcessor.outputSize(for: first)
                ToolSettingRow("Output size") {
                    Text(verbatim: "\(VideoText.size(size.width, size.height)) · \(VideoSpeedProcessor.label((VideoExport.frameRate(first) * 100).rounded() / 100)) fps")
                        .font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ToolSettingRow("Total duration") {
                Text(VideoText.time(totalDuration))
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
            }
            if mismatchedSize {
                VideoHint("Videos with a different size are scaled to fit and letterboxed.")
            }
            if missingAudio {
                VideoHint("Videos without sound get silence so the audio stays in sync.")
            }
        }
    }

    private func details(for item: Item) -> String {
        guard let info = item.info else { return FileNaming.formattedSize(item.bytes) }
        let size = info.displaySize
        var parts = [VideoText.size(size), FileNaming.formatTime(info.duration), FileNaming.formattedSize(item.bytes)]
        if !info.hasAudio { parts.append("No audio") }
        return parts.joined(separator: " · ")
    }

    private func move(_ index: Int, by offset: Int) {
        move(index, to: index + offset)
    }

    private func move(_ index: Int, to target: Int) {
        guard items.indices.contains(index), items.indices.contains(target), index != target else { return }
        withAnimation {
            let item = items.remove(at: index)
            items.insert(item, at: target)
        }
    }

    private func load() async {
        for url in items.map(\.url) {
            let info = try? await MediaInfo.probe(url)
            let time = min(1, (info?.duration ?? 0) * 0.1)
            let thumbnail = await VideoFrames.frame(source: url, playable: url, at: time, maxSize: 160)
            if let index = items.firstIndex(where: { $0.url == url }) {
                items[index].info = info
                items[index].thumbnail = thumbnail
            }
        }
    }

    private func join() {
        let order = items.map(\.url)
        session.runBatch { _, context in
            [try await JoinVideosProcessor.join(order, context: context)]
        }
    }
}
