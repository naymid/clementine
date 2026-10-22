import SwiftUI

/// Editors for the video tools.
@MainActor
enum VideoTools: ToolGroup {
    static let tools: Set<FileTool> = [.trimVideo, .cropVideo, .changeVideoSpeed, .splitVideo, .videoSnapshots, .redactVideo, .joinVideos, .muteVideo]

    static func makeEditor(for session: ToolSession) -> ToolEditor? {
        guard !session.urls.isEmpty else { return nil }
        switch session.tool {
        case .trimVideo:
            return ToolEditor(TrimVideoEditor(session: session), size: CGSize(width: 760, height: 620), minSize: CGSize(width: 600, height: 520))
        case .cropVideo:
            return ToolEditor(CropVideoEditor(session: session), size: CGSize(width: 900, height: 600), minSize: CGSize(width: 740, height: 520))
        case .changeVideoSpeed:
            return ToolEditor(ChangeVideoSpeedEditor(session: session), size: CGSize(width: 880, height: 560), minSize: CGSize(width: 740, height: 520))
        case .splitVideo:
            return ToolEditor(SplitVideoEditor(session: session), size: CGSize(width: 800, height: 660), minSize: CGSize(width: 660, height: 580))
        case .videoSnapshots:
            return ToolEditor(VideoSnapshotsEditor(session: session), size: CGSize(width: 780, height: 680), minSize: CGSize(width: 640, height: 600))
        case .redactVideo:
            return ToolEditor(RedactVideoEditor(session: session), size: CGSize(width: 880, height: 740), minSize: CGSize(width: 760, height: 640))
        case .joinVideos:
            return ToolEditor(JoinVideosEditor(session: session), size: CGSize(width: 600, height: 560), minSize: CGSize(width: 500, height: 440))
        default:
            return nil
        }
    }

    /// Mute Video works straight from the wheel: every dropped video gets a silent copy.
    static func runImmediately(_ session: ToolSession) {
        switch session.tool {
        case .muteVideo:
            session.runPerItem { url, context in
                [try await MuteVideoProcessor.mute(url, context: context)]
            }
        default:
            ToolCoordinator.shared.showUnavailable(session)
        }
    }

    static func registerSnapshots() {
        registerTests()
        registerDesignStates()
    }

    // MARK: Headless tests

    /// `Clementine --tool-test <tool> <files…> key=value…`
    private static func registerTests() {
        func number(_ options: [String: String], _ key: String, _ fallback: Double) -> Double {
            options[key].flatMap(Double.init) ?? fallback
        }
        func numbers(_ text: String?) -> [Double] {
            (text ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        func first(_ files: [URL]) throws -> URL {
            guard let url = files.first else { throw ProcessError.failed("Pass a video file.") }
            return url
        }

        // start=0.5 end=2 mode=accurate|fast
        ToolTestRegistry.tests["trimVideo"] = { files, options, context in
            let mode = TrimVideoProcessor.Mode(rawValue: options["mode"] ?? "accurate") ?? .accurate
            return [try await TrimVideoProcessor.trim(try first(files), start: number(options, "start", 0),
                                                      end: number(options, "end", 1), mode: mode, context: context)]
        }
        // rect=x,y,w,h (display pixels) or aspect=square|wide|tall|portrait|classic
        ToolTestRegistry.tests["cropVideo"] = { files, options, context in
            let url = try first(files)
            var rect: CGRect
            let values = numbers(options["rect"])
            if values.count == 4 {
                rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            } else {
                let info = try await VideoExport.probe(url)
                let bounds = CGRect(origin: .zero, size: info.displaySize)
                let aspect = VideoCropAspect(rawValue: options["aspect"] ?? "square") ?? .square
                rect = aspect.ratio(for: info.displaySize).map { VideoRectMath.largest(ratio: $0, in: bounds) } ?? bounds
            }
            return [try await CropVideoProcessor.crop(url, rect: rect, context: context)]
        }
        // speed=2 audio=keep|mute
        ToolTestRegistry.tests["changeVideoSpeed"] = { files, options, context in
            [try await VideoSpeedProcessor.change(try first(files), speed: number(options, "speed", 2),
                                                  keepAudio: options["audio"] != "mute", context: context)]
        }
        // splits=1,2 remove=2 (1-based clip numbers) mode=separate|one
        ToolTestRegistry.tests["splitVideo"] = { files, options, context in
            let url = try first(files)
            let info = try await VideoExport.probe(url)
            var plan = VideoSplitPlan(duration: info.duration)
            for time in numbers(options["splits"]) where !plan.addSplit(at: time) {
                throw ProcessError.failed("Split points must be at least 0.05 seconds apart.")
            }
            for number in numbers(options["remove"]) { plan.setRemoved(true, clip: Int(number) - 1) }
            if options["mode"] == "one" {
                return [try await SplitVideoProcessor.exportJoined(url, clips: plan.keptClips, context: context)]
            }
            return try await SplitVideoProcessor.exportClips(url, clips: plan.keptClips, context: context)
        }
        // times=0.5,1.25
        ToolTestRegistry.tests["videoSnapshots"] = { files, options, context in
            try await VideoSnapshotsProcessor.save(try first(files), times: numbers(options["times"] ?? "0"), context: context)
        }
        // boxes=x,y,w,h,start,end;… (display pixels, seconds) style=solid|blur
        ToolTestRegistry.tests["redactVideo"] = { files, options, context in
            let redactions = (options["boxes"] ?? "").split(separator: ";").compactMap { item -> VideoRedaction? in
                let values = numbers(String(item))
                guard values.count == 6 else { return nil }
                return VideoRedaction(rect: CGRect(x: values[0], y: values[1], width: values[2], height: values[3]),
                                      start: values[4], end: values[5])
            }
            let style = RedactVideoProcessor.Style(rawValue: options["style"] ?? "solid") ?? .solid
            return [try await RedactVideoProcessor.redact(try first(files), redactions: redactions, style: style, context: context)]
        }
        // files in join order; sort=name orders them as Finder does
        ToolTestRegistry.tests["joinVideos"] = { files, options, context in
            let order = options["sort"] == "name" ? JoinVideosProcessor.sortedByName(files) : files
            return [try await JoinVideosProcessor.join(order, context: context)]
        }
        ToolTestRegistry.tests["muteVideo"] = { files, _, context in
            var outputs: [URL] = []
            for url in files { outputs.append(try await MuteVideoProcessor.mute(url, context: context)) }
            return outputs
        }
        // The math behind the editors' drag gestures and split timeline. No files needed.
        ToolTestRegistry.tests["videoEditorMath"] = { _, _, _ in
            try checkEditorMath()
            print("video editor math: all checks passed")
            return []
        }
    }

    private static func checkEditorMath() throws {
        func expect(_ condition: Bool, _ name: String) throws {
            guard condition else { throw ProcessError.failed("check failed: \(name)") }
        }
        func same(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
        }
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        // Free resize from the bottom-right corner.
        try expect(same(VideoRectMath.resized(frame, handle: .bottomRight, by: CGSize(width: -100, height: -50), within: frame,
                                              ratio: nil, minimumSize: 16), CGRect(x: 0, y: 0, width: 1180, height: 670)), "free corner resize")
        // Square crop dragged past the frame stays square and inside.
        try expect(same(VideoRectMath.resized(CGRect(x: 280, y: 0, width: 720, height: 720), handle: .bottomRight,
                                              by: CGSize(width: 200, height: 10), within: frame, ratio: 1, minimumSize: 16),
                        CGRect(x: 280, y: 0, width: 720, height: 720)), "locked ratio clamps to frame")
        // Edge handle with a ratio keeps the other axis centered.
        try expect(same(VideoRectMath.resized(CGRect(x: 100, y: 100, width: 200, height: 100), handle: .right,
                                              by: CGSize(width: 100, height: 0), within: frame, ratio: 2, minimumSize: 16),
                        CGRect(x: 100, y: 75, width: 300, height: 150)), "edge handle with ratio")
        // Left handle cannot cross the right edge.
        try expect(same(VideoRectMath.resized(CGRect(x: 100, y: 100, width: 200, height: 100), handle: .left,
                                              by: CGSize(width: 500, height: 0), within: frame, ratio: nil, minimumSize: 16),
                        CGRect(x: 284, y: 100, width: 16, height: 100)), "minimum size")
        // Moving is clamped to the frame.
        try expect(same(VideoRectMath.moved(CGRect(x: 100, y: 100, width: 200, height: 100), by: CGSize(width: 2000, height: -500), within: frame),
                        CGRect(x: 1080, y: 0, width: 200, height: 100)), "move clamps")
        // Drawing up-left from the start point.
        try expect(same(VideoRectMath.spanning(CGPoint(x: 100, y: 100), CGPoint(x: 50, y: 20), within: frame, ratio: nil),
                        CGRect(x: 50, y: 20, width: 50, height: 80)), "draw up-left")
        // Drawing with 16:9 past the frame edge.
        try expect(same(VideoRectMath.spanning(.zero, CGPoint(x: 1600, y: 10), within: frame, ratio: 16.0 / 9.0),
                        CGRect(x: 0, y: 0, width: 1280, height: 720)), "draw with ratio")
        // Largest 9:16 rect, pushed back inside the frame.
        try expect(same(VideoRectMath.largest(ratio: 9.0 / 16.0, in: frame, centeredOn: CGPoint(x: 1200, y: 360)),
                        CGRect(x: 875, y: 0, width: 405, height: 720)), "largest with ratio")
        // Even crop sizes inside the frame.
        try expect(CropVideoProcessor.pixelRect(CGRect(x: 100, y: 50, width: 641, height: 361), in: frame.size)
                   == .init(x: 100, y: 50, width: 640, height: 360), "even crop")
        // Redaction boxes are even-aligned and cover the requested area.
        if let box = RedactVideoProcessor.box(CGRect(x: 101, y: 51, width: 99, height: 49), in: frame.size) {
            try expect(box.x == 100 && box.y == 50 && box.x + box.width >= 200 && box.y + box.height >= 100
                       && box.width % 2 == 0 && box.height % 2 == 0, "redaction box")
        } else {
            try expect(false, "redaction box")
        }
        // Timeline mapping round-trips.
        let metrics = VideoTimelineMetrics(width: 616, duration: 12)
        try expect(abs(metrics.time(metrics.x(7.25)) - 7.25) < 0.0001, "timeline round trip")
        // Split plan: gaps, removal, skipping, merging.
        var plan = VideoSplitPlan(duration: 10)
        try expect(plan.addSplit(at: 5), "add split")
        try expect(!plan.addSplit(at: 5.03), "split gap enforced")
        try expect(!plan.addSplit(at: 0.02), "split near start rejected")
        try expect(plan.addSplit(at: 2.5), "add earlier split")
        try expect(plan.clips.map(\.start) == [0, 2.5, 5], "clips ordered")
        plan.setRemoved(true, clip: 1)
        try expect(plan.skipTarget(from: 3) == 5 && plan.skipTarget(from: 1) == nil, "playback skips removed clip")
        plan.setRemoved(true, clip: 2)
        try expect(plan.skipTarget(from: 3) == 10, "playback stops after last kept clip")
        try expect(plan.addSplit(at: 7.5) && plan.clips[3].removed, "split inside removed clip stays removed")
        plan.removeSplit(at: 0)
        try expect(plan.clips.count == 3 && !plan.clips[0].removed && plan.keptClips.count == 1, "merging keeps a kept half")
        plan.moveSplit(0, to: 7.49)
        try expect(abs(plan.points[0] - 7.45) < 0.0001, "moving respects the gap")
        // Speed helpers.
        try expect(VideoSpeedProcessor.atempoChain(0.25) == "atempo=0.5,atempo=0.5", "atempo 0.25")
        try expect(VideoSpeedProcessor.atempoChain(4) == "atempo=2,atempo=2", "atempo 4")
        try expect(VideoSpeedProcessor.atempoChain(3) == "atempo=2,atempo=1.5", "atempo 3")
        try expect(VideoSpeedProcessor.label(0.75) == "0.75" && VideoSpeedProcessor.label(2) == "2", "speed labels")
        try expect(VideoSnapshotsProcessor.suffix(for: 72.9) == "-01m12s" && VideoSnapshotsProcessor.suffix(for: 3725) == "-1h02m05s",
                   "snapshot names")
    }

    // MARK: Design snapshots with content

    /// Editors with some work already done, for `--snapshot tool-<name>-demo`.
    private static func registerDesignStates() {
        func entry<V: View>(_ tool: FileTool, _ files: [URL], size: CGSize, _ make: (ToolSession) -> V) -> SnapshotRegistry.Entry {
            let session = ToolSession(tool: tool, urls: files)
            return SnapshotRegistry.Entry(view: AnyView(make(session).environmentObject(session)), size: size)
        }
        SnapshotRegistry.builders["tool-cropVideo-demo"] = { files, _ in
            entry(.cropVideo, files, size: CGSize(width: 900, height: 600)) { CropVideoEditor(session: $0, initialAspect: .square) }
        }
        SnapshotRegistry.builders["tool-splitVideo-demo"] = { files, _ in
            entry(.splitVideo, files, size: CGSize(width: 800, height: 660)) {
                SplitVideoEditor(session: $0, initialSplits: [1.0, 2.0], initialRemoved: [1])
            }
        }
        SnapshotRegistry.builders["tool-videoSnapshots-demo"] = { files, _ in
            entry(.videoSnapshots, files, size: CGSize(width: 780, height: 680)) {
                VideoSnapshotsEditor(session: $0, initialTimes: [0.4, 1.2, 2.5])
            }
        }
        SnapshotRegistry.builders["tool-redactVideo-demo"] = { files, _ in
            entry(.redactVideo, files, size: CGSize(width: 880, height: 740)) {
                RedactVideoEditor(session: $0, initialAreas: [
                    (CGRect(x: 0.08, y: 0.12, width: 0.3, height: 0.3), 0, 3),
                    (CGRect(x: 0.55, y: 0.5, width: 0.32, height: 0.36), 0, 2.2),
                ])
            }
        }
    }
}
