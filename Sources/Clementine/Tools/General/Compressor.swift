import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// What the Compress editor asks for.
struct CompressionRequest {
    var strength: CompressionStrength = .balanced
    var imageSize: ImageSizeLimit = .original
    var maxVideoHeight = 0
    var targetBytes: Int64?

    static let minimumTarget: Int64 = 1_000
    static let maximumTarget: Int64 = 1_000_000_000_000
}

enum CompressionText {
    static let exceeds = "Compressed output would exceed the original or target file size."
    static let targetRange = "Enter a target size between 1 KB and 1 TB."
    static let targetAboveOriginal = "Target size cannot exceed the original file size."
    static let tooSmallForDuration = "The target is too small for this duration. Choose a larger size."
    static let videoDoesNotFit = "The encoder could not fit this video within the target. Choose a larger size."
    static let videoUnverified = "The compressed video's duration or tracks could not be verified."
    static let pdfUnverified = "The compressed PDF could not be verified."
    static let animation = "Compression cannot preserve this animation. Use a GIF or a video instead."

    static func unreachable(_ smallest: Int64) -> String {
        "Could not reach the target size. Smallest attempt was \(FileNaming.formattedSize(smallest)). Try a larger target."
    }
}

/// Compresses images, GIFs, video, audio and PDFs into a smaller copy of the same format.
enum FileCompressor {
    /// Everything one compression run needs.
    struct Work {
        var source: URL
        var format: FileFormat
        var request: CompressionRequest
        var originalSize: Int64
        /// The output must be at most this many bytes (below the original, and within the target).
        var limit: Int64
        var scratch: URL
        var output: URL
        var context: JobContext
        var hasTarget: Bool { request.targetBytes != nil }
    }

    static func compress(_ url: URL, request: CompressionRequest, context: JobContext) async throws -> URL {
        guard let format = FileFormat.detect(url), FileTool.compress.applies(to: [format]) else {
            throw GeneralToolFailure("This file type is not supported.")
        }
        let original = GeneralSizeText.bytes(of: url)
        guard original > 0 else { throw GeneralToolFailure("File size unavailable.") }
        if let target = request.targetBytes,
           target < CompressionRequest.minimumTarget || target > CompressionRequest.maximumTarget {
            throw GeneralToolFailure(CompressionText.targetRange)
        }
        let limit = min(request.targetBytes ?? original, original - 1)
        guard limit > 0 else { throw GeneralToolFailure(CompressionText.exceeds) }
        let scratch = try FileNaming.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let ext = url.pathExtension.isEmpty ? format.outputExtension : url.pathExtension
        let work = Work(source: url, format: format, request: request, originalSize: original, limit: limit,
                        scratch: scratch, output: scratch.appendingPathComponent("compressed.\(ext)"), context: context)
        context.progress(0.02)
        switch format {
        case .pdf: try await compressPDF(work)
        case .gif: try await compressGIF(work)
        case _ where format.family == .video: try await compressVideo(work)
        case _ where format.family == .audio: try await compressAudio(work)
        default: try await compressImage(work)
        }
        try context.checkCancelled()
        let size = GeneralSizeText.bytes(of: work.output)
        guard size > 0 else { throw ConversionError.noOutput }
        guard size <= limit else { throw GeneralToolFailure(CompressionText.exceeds) }
        let destination = FileNaming.output(beside: url, suffix: "-smaller", extension: ext)
        try FileManager.default.moveItem(at: work.output, to: destination)
        context.progress(1)
        return destination
    }

    // MARK: - Images

    static func lossyQuality(_ format: FileFormat, _ strength: CompressionStrength) -> Double {
        switch (format, strength) {
        case (.heic, .balanced), (.avif, .balanced): return 0.6
        case (.heic, .strong), (.avif, .strong): return 0.42
        case (.webp, .balanced): return 0.72
        case (.webp, .strong): return 0.5
        case (_, .balanced): return 0.72
        case (_, .strong): return 0.5
        }
    }

    private static func compressImage(_ work: Work) async throws {
        if [.png, .webp].contains(work.format),
           let source = CGImageSourceCreateWithURL(work.source as CFURL, nil), CGImageSourceGetCount(source) > 1 {
            throw GeneralToolFailure(CompressionText.animation)
        }
        let loaded = try ImageIOHelpers.load(work.source, maxPixel: work.request.imageSize.longestEdge)
        let preserve = AppSettings.shared.options(for: work.format).preserveMetadata
        let properties = preserve ? loaded.properties : nil
        work.context.progress(0.1)
        switch work.format {
        case .jpg, .heic, .avif, .webp:
            let quality = lossyQuality(work.format, work.request.strength)
            var pngInput: (image: CGImage, url: URL)?
            let encode: (CGImage, Double) async throws -> Int64 = { image, quality in
                if work.format == .webp {
                    if pngInput == nil || pngInput!.image !== image {
                        let url = work.scratch.appendingPathComponent("webp-input-\(image.width).png")
                        try ImageIOHelpers.write(image, to: url, format: .png, quality: nil, properties: properties)
                        pngInput = (image, url)
                    }
                    var options = AppSettings.shared.options(for: .webp)
                    options.preserveMetadata = preserve
                    try await ImageConverter.writeWebP(source: pngInput!.url, format: .png, to: work.output, options: options,
                                                       context: work.context, qualityOverride: quality)
                } else {
                    try ImageIOHelpers.write(image, to: work.output, format: work.format, quality: quality, properties: properties)
                }
                return GeneralSizeText.bytes(of: work.output)
            }
            if work.hasTarget {
                try await fitByQuality(work, image: loaded.image, maxQuality: min(0.9, quality + 0.15), encode: encode)
            } else {
                _ = try await encode(loaded.image, quality)
            }
        case .tiff:
            try await compressTIFF(work, image: loaded.image, properties: properties)
        case .bmp:
            try await compressBMP(work, image: loaded.image)
        default:
            try await compressPNG(work, image: loaded.image, properties: properties)
        }
    }

    /// Finds the highest quality that fits the limit, scaling the image down when even low quality is too large.
    private static func fitByQuality(_ work: Work, image base: CGImage, maxQuality: Double,
                                     encode: (CGImage, Double) async throws -> Int64) async throws {
        var image = base
        var smallest = Int64.max
        for round in 0..<8 {
            try work.context.checkCancelled()
            work.context.progress(0.1 + Double(round) * 0.1)
            let best = try await encode(image, maxQuality)
            smallest = min(smallest, best)
            if best <= work.limit { return }
            // Prefer scaling over very low quality until the last rounds.
            let floorQuality = round < 4 ? 0.35 : 0.08
            let worst = try await encode(image, floorQuality)
            smallest = min(smallest, worst)
            if worst <= work.limit {
                var low = floorQuality, high = maxQuality
                for _ in 0..<6 {
                    let middle = (low + high) / 2
                    if try await encode(image, middle) <= work.limit { low = middle } else { high = middle }
                }
                let final = try await encode(image, low)
                smallest = min(smallest, final)
                if final <= work.limit { return }
            }
            let ratio = min(0.85, (Double(work.limit) / Double(worst)).squareRoot() * 0.92)
            let longest = Int(Double(max(image.width, image.height)) * ratio)
            guard longest >= 16 else { break }
            image = ImageIOHelpers.resize(image, longestEdge: longest)
        }
        throw GeneralToolFailure(CompressionText.unreachable(smallest))
    }

    /// PNG: palette quantization keeps transparency; fewer colors and then smaller sizes for targets.
    private static func compressPNG(_ work: Work, image base: CGImage, properties: [CFString: Any]?) async throws {
        let srgb = convertToSRGB(base)
        let alpha = PNGPalette.alphaKind(of: srgb)
        let encode: (CGImage, Int) async throws -> Int64 = { image, colors in
            if alpha == .soft {
                try PNGPalette.writeQuantized(image, colors: colors, to: work.output)
            } else {
                try await ffmpegQuantize(image, colors: colors, transparent: alpha == .binary, work: work, pixelFormat: nil)
            }
            return GeneralSizeText.bytes(of: work.output)
        }
        let preset = work.request.strength == .balanced ? 256 : 96
        if !work.hasTarget {
            let quantized = try await encode(srgb, preset)
            if quantized > work.limit {
                // Already-optimized palettes can grow; a lossless re-encode is the other option.
                let lossless = work.scratch.appendingPathComponent("lossless.png")
                try ImageIOHelpers.write(base, to: lossless, format: .png, quality: nil, properties: properties)
                if GeneralSizeText.bytes(of: lossless) < quantized {
                    try FileManager.default.removeItem(at: work.output)
                    try FileManager.default.moveItem(at: lossless, to: work.output)
                }
            }
            return
        }
        var smallest = Int64.max
        for (step, colors) in [256, 192, 128, 96, 64, 48, 32].filter({ $0 <= preset }).enumerated() {
            try work.context.checkCancelled()
            work.context.progress(0.1 + Double(step) * 0.06)
            let size = try await encode(srgb, colors)
            smallest = min(smallest, size)
            if size <= work.limit { return }
        }
        var image = srgb
        for _ in 0..<8 {
            let ratio = min(0.85, (Double(work.limit) / Double(max(smallest, 1))).squareRoot() * 0.92)
            let longest = Int(Double(max(image.width, image.height)) * ratio)
            guard longest >= 16 else { break }
            image = ImageIOHelpers.resize(image, longestEdge: longest)
            let size = try await encode(image, 64)
            smallest = min(smallest, size)
            if size <= work.limit { return }
        }
        throw GeneralToolFailure(CompressionText.unreachable(smallest))
    }

    /// Palette output through ffmpeg (palettegen + paletteuse).
    private static func ffmpegQuantize(_ image: CGImage, colors: Int, transparent: Bool, work: Work, pixelFormat: String?) async throws {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw ProcessError.missingTool("ffmpeg") }
        let input = work.scratch.appendingPathComponent("quantize-input.png")
        try ImageIOHelpers.write(image, to: input, format: .png, quality: nil)
        let filter = "split[a][b];[a]palettegen=max_colors=\(colors):stats_mode=full:reserve_transparent=\(transparent ? 1 : 0)[p];"
            + "[b][p]paletteuse=dither=sierra2_4a:alpha_threshold=128"
        var arguments = ["-y", "-v", "error", "-i", input.path, "-filter_complex", filter, "-frames:v", "1", "-update", "1"]
        if let pixelFormat { arguments += ["-pix_fmt", pixelFormat] }
        arguments.append(work.output.path)
        try await work.context.runner.run(ffmpeg, arguments)
    }

    private static func compressTIFF(_ work: Work, image base: CGImage, properties: [CFString: Any]?) async throws {
        let hasAlpha = PNGPalette.alphaKind(of: base) != .opaque
        func write(_ image: CGImage, compression: Int, quality: Double?) throws -> Int64 {
            var props = properties ?? [:]
            var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = compression
            props[kCGImagePropertyTIFFDictionary] = tiff
            try ImageIOHelpers.write(compression == 7 ? ImageIOHelpers.flatten(image) : image, to: work.output,
                                     format: .tiff, quality: quality, properties: props)
            return GeneralSizeText.bytes(of: work.output)
        }
        let lossless: (CGImage) throws -> Int64 = { image in
            // Deflate usually wins; LZW is kept when it is smaller.
            let deflate = try write(image, compression: 8, quality: nil)
            let deflateURL = work.scratch.appendingPathComponent("deflate.tiff")
            try? FileManager.default.removeItem(at: deflateURL)
            try FileManager.default.copyItem(at: work.output, to: deflateURL)
            let lzw = try write(image, compression: 5, quality: nil)
            if deflate <= lzw {
                try FileManager.default.removeItem(at: work.output)
                try FileManager.default.moveItem(at: deflateURL, to: work.output)
                return deflate
            }
            return lzw
        }
        if !work.hasTarget {
            if work.request.strength == .strong && !hasAlpha {
                _ = try write(base, compression: 7, quality: 0.6)
            } else {
                _ = try lossless(base)
            }
            return
        }
        if try lossless(base) <= work.limit { return }
        if hasAlpha {
            var image = base
            var smallest = GeneralSizeText.bytes(of: work.output)
            for _ in 0..<8 {
                let ratio = min(0.85, (Double(work.limit) / Double(smallest)).squareRoot() * 0.92)
                let longest = Int(Double(max(image.width, image.height)) * ratio)
                guard longest >= 16 else { break }
                image = ImageIOHelpers.resize(image, longestEdge: longest)
                let size = try lossless(image)
                smallest = min(smallest, size)
                if smallest <= work.limit { return }
            }
            throw GeneralToolFailure(CompressionText.unreachable(smallest))
        }
        try await fitByQuality(work, image: base, maxQuality: 0.85) { image, quality in
            try write(image, compression: 7, quality: quality)
        }
    }

    /// BMP has no compression of its own: fewer bits per pixel (16-bit, then 8-bit palette).
    private static func compressBMP(_ work: Work, image base: CGImage) async throws {
        let encode: (CGImage, Bool) async throws -> Int64 = { image, palette in
            if palette {
                try await ffmpegQuantize(image, colors: 256, transparent: false, work: work, pixelFormat: "pal8")
            } else {
                guard let ffmpeg = ToolPaths.ffmpeg else { throw ProcessError.missingTool("ffmpeg") }
                let input = work.scratch.appendingPathComponent("bmp-input.png")
                try ImageIOHelpers.write(ImageIOHelpers.flatten(image), to: input, format: .png, quality: nil)
                try await work.context.runner.run(ffmpeg, ["-y", "-v", "error", "-i", input.path, "-frames:v", "1", "-update", "1",
                                                           "-pix_fmt", "rgb565le", work.output.path])
            }
            return GeneralSizeText.bytes(of: work.output)
        }
        if !work.hasTarget {
            _ = try await encode(base, work.request.strength == .strong)
            return
        }
        var smallest = try await encode(base, false)
        if smallest <= work.limit { return }
        var image = base
        let paletteSize = try await encode(image, true)
        smallest = min(smallest, paletteSize)
        if smallest <= work.limit { return }
        for _ in 0..<8 {
            let ratio = min(0.85, (Double(work.limit) / Double(smallest)).squareRoot() * 0.95)
            let longest = Int(Double(max(image.width, image.height)) * ratio)
            guard longest >= 16 else { break }
            image = ImageIOHelpers.resize(image, longestEdge: longest)
            let size = try await encode(image, true)
            smallest = min(smallest, size)
            if smallest <= work.limit { return }
        }
        throw GeneralToolFailure(CompressionText.unreachable(smallest))
    }

    static func convertToSRGB(_ image: CGImage) -> CGImage {
        if let name = image.colorSpace?.name, name == CGColorSpace.sRGB, image.bitsPerComponent == 8 { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    // MARK: - GIF

    private static func compressGIF(_ work: Work) async throws {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw ProcessError.missingTool("ffmpeg") }
        let info = try await MediaInfo.probe(work.source)
        let sourceWidth = max(2, info.width)
        let sourceRate = info.frameRate > 0 ? info.frameRate : 15
        struct Step { var colors: Int; var fps: Double; var scale: Double }
        let balanced = Step(colors: 128, fps: min(sourceRate, 15), scale: 1)
        let strong = Step(colors: 64, fps: min(sourceRate, 10), scale: min(1, 480 / Double(sourceWidth)))
        func encode(_ step: Step) async throws -> Int64 {
            let width = max(2, Int(Double(sourceWidth) * step.scale) / 2 * 2)
            let filter = "fps=\(String(format: "%.3f", step.fps)),scale=\(width):-1:flags=lanczos,split[a][b];"
                + "[a]palettegen=max_colors=\(step.colors):stats_mode=diff[p];"
                + "[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
            try await MediaConverter.run(ffmpeg, ["-y", "-hide_banner", "-nostdin", "-i", work.source.path,
                                                  "-filter_complex", filter, "-loop", "0", work.output.path],
                                         duration: info.duration, context: work.context, progressRange: 0.05...0.95)
            return GeneralSizeText.bytes(of: work.output)
        }
        let preset = work.request.strength == .balanced ? balanced : strong
        if !work.hasTarget {
            _ = try await encode(preset)
            return
        }
        let ladder = [preset,
                      Step(colors: 96, fps: min(sourceRate, 12), scale: min(preset.scale, 0.85)),
                      Step(colors: 64, fps: min(sourceRate, 10), scale: min(preset.scale, 0.7)),
                      Step(colors: 48, fps: min(sourceRate, 10), scale: min(preset.scale, 0.55)),
                      Step(colors: 32, fps: min(sourceRate, 8), scale: min(preset.scale, 0.45)),
                      Step(colors: 24, fps: min(sourceRate, 8), scale: min(preset.scale, 0.35)),
                      Step(colors: 16, fps: min(sourceRate, 6), scale: min(preset.scale, 0.25))]
        var smallest = Int64.max
        for step in ladder {
            try work.context.checkCancelled()
            let size = try await encode(step)
            smallest = min(smallest, size)
            if size <= work.limit { return }
        }
        throw GeneralToolFailure(CompressionText.unreachable(smallest))
    }

    // MARK: - Video

    private static func compressVideo(_ work: Work) async throws {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw ProcessError.missingTool("ffmpeg") }
        let info = try await MediaInfo.probe(work.source)
        guard info.hasVideo else { throw GeneralToolFailure("This file has no video track.") }
        let strong = work.request.strength == .strong
        let filter = MediaConverter.scaleFilter(maxHeight: work.request.maxVideoHeight, info: info)
        let ext = work.output.pathExtension.lowercased()
        var audioKbps = strong ? 96 : 128
        if ext == "webm" { audioKbps = strong ? 64 : 96 }

        func audioArguments(_ kbps: Int) -> [String] {
            guard info.hasAudio else { return ["-an"] }
            switch ext {
            case "webm": return ["-c:a", "libopus", "-b:a", "\(kbps)k"]
            case "avi": return ["-c:a", "libmp3lame", "-b:a", "\(kbps)k"]
            case "wmv": return ["-c:a", "wmav2", "-b:a", "\(max(kbps, 48))k"]
            default: return ["-c:a", "aac", "-b:a", "\(kbps)k"]
            }
        }
        /// Encoder arguments; `bitrate` switches from constant quality to a bitrate for target sizes.
        func videoArguments(bitrate: Int?) -> [String] {
            let crf = strong ? 32 : 26
            switch ext {
            case "webm":
                var arguments = ["-c:v", "libvpx-vp9", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
                arguments += bitrate.map { ["-b:v", "\($0)k"] } ?? ["-crf", "\(crf + 10)", "-b:v", "0"]
                return arguments
            case "avi":
                return ["-c:v", "mpeg4", "-vtag", "xvid"] + (bitrate.map { ["-b:v", "\($0)k"] } ?? ["-q:v", strong ? "9" : "5"])
            case "wmv":
                return ["-c:v", "wmv2"] + (bitrate.map { ["-b:v", "\($0)k"] } ?? ["-q:v", strong ? "10" : "6"])
            default:
                var arguments = ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p"]
                arguments += bitrate.map { ["-b:v", "\($0)k"] } ?? ["-crf", "\(crf)"]
                if ext == "mov" { arguments += ["-tag:v", "avc1"] }
                return arguments
            }
        }
        var container: [String] = []
        if ext == "mp4" || ext == "mov" || ext == "m4v" { container = ["-movflags", "+faststart"] }
        let input: [String] = ["-y", "-hide_banner", "-nostdin", "-i", work.source.path]
        func fullArguments(bitrate: Int?, pass: [String], audioKbps: Int, filter: String) -> [String] {
            var arguments = input
            arguments += ["-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0", "-vf", filter]
            arguments += videoArguments(bitrate: bitrate)
            arguments += pass
            arguments += audioArguments(audioKbps)
            arguments += container
            arguments.append(work.output.path)
            return arguments
        }

        if !work.hasTarget {
            try await MediaConverter.run(ffmpeg, fullArguments(bitrate: nil, pass: [], audioKbps: audioKbps, filter: filter),
                                         duration: info.duration, context: work.context, progressRange: 0.03...0.97)
            try await verifyVideo(work.output, against: info)
            return
        }

        guard info.duration > 0 else { throw GeneralToolFailure(CompressionText.tooSmallForDuration) }
        // Bits available for the whole file, less ~3% for the container.
        let totalKbps = Double(work.limit) * 8 * 0.97 / info.duration / 1000
        if info.hasAudio && totalKbps < Double(audioKbps) * 3 { audioKbps = ext == "webm" ? 32 : 48 }
        var videoKbps = Int(totalKbps - (info.hasAudio ? Double(audioKbps) : 0))
        guard videoKbps >= 24 else { throw GeneralToolFailure(CompressionText.tooSmallForDuration) }
        // x264 and VP9 use two passes; the older AVI/WMV encoders reject low two-pass bitrates, so they use one.
        let twoPass = !(ext == "avi" || ext == "wmv")
        let passLog = work.scratch.appendingPathComponent("passlog").path
        for attempt in 0..<3 {
            try work.context.checkCancelled()
            // Very low bitrates look better (and fit) at a smaller frame size.
            let targetFilter = lowBitrateFilter(info: info, maxHeight: work.request.maxVideoHeight, videoKbps: videoKbps,
                                                minimumBitsPerPixel: twoPass ? 0.015 : 0.05) ?? filter
            let base = Double(attempt) / 3
            let span = 1.0 / 3
            if twoPass {
                var firstPass = input
                firstPass += ["-map", "0:v:0", "-vf", targetFilter]
                firstPass += videoArguments(bitrate: videoKbps)
                firstPass += ["-pass", "1", "-passlogfile", passLog, "-an", "-f", "null", "-"]
                try await MediaConverter.run(ffmpeg, firstPass, duration: info.duration, context: work.context,
                                             progressRange: base...(base + span * 0.4))
            }
            let pass = twoPass ? ["-pass", "2", "-passlogfile", passLog] : []
            let encode = fullArguments(bitrate: videoKbps, pass: pass, audioKbps: audioKbps, filter: targetFilter)
            try await MediaConverter.run(ffmpeg, encode, duration: info.duration, context: work.context,
                                         progressRange: (base + span * (twoPass ? 0.4 : 0))...(base + span))
            let size = GeneralSizeText.bytes(of: work.output)
            if size <= work.limit {
                try await verifyVideo(work.output, against: info)
                return
            }
            // Over the target: retry with a proportionally lower bitrate.
            videoKbps = Int(Double(videoKbps) * Double(work.limit) / Double(size) * 0.92)
            guard videoKbps >= 24 else { break }
        }
        throw GeneralToolFailure(CompressionText.videoDoesNotFit)
    }

    /// A smaller frame height when the bitrate leaves too few bits per pixel, or nil to keep the size.
    private static func lowBitrateFilter(info: MediaInfo, maxHeight: Int, videoKbps: Int, minimumBitsPerPixel: Double) -> String? {
        let display = info.displaySize
        guard display.width > 0, display.height > 0 else { return nil }
        var height = Double(display.height)
        if maxHeight > 0 { height = min(height, Double(maxHeight)) }
        let width = Double(display.width) * height / Double(display.height)
        let bitsPerPixel = Double(videoKbps) * 1000 / (width * height * max(info.frameRate, 1))
        guard bitsPerPixel < minimumBitsPerPixel else { return nil }
        let scaled = Int(height * (bitsPerPixel / minimumBitsPerPixel).squareRoot()) / 2 * 2
        return "scale=-2:\(max(96, scaled))"
    }

    private static func verifyVideo(_ url: URL, against original: MediaInfo) async throws {
        guard let info = try? await MediaInfo.probe(url), info.hasVideo, info.hasAudio == original.hasAudio,
              original.duration <= 0 || abs(info.duration - original.duration) <= max(1, original.duration * 0.05) else {
            throw GeneralToolFailure(CompressionText.videoUnverified)
        }
    }

    // MARK: - Audio

    private struct AudioStream {
        var sampleRate = 44_100
        var channels = 2
        var bitsPerSample = 16
    }

    private static func probeAudio(_ url: URL) async -> AudioStream {
        var stream = AudioStream()
        guard let ffprobe = ToolPaths.ffprobe,
              let result = try? await ProcessRunner().run(ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_entries",
                                                                    "stream=sample_rate,channels,bits_per_sample,bits_per_raw_sample,sample_fmt",
                                                                    "-of", "json", url.path]),
              let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let first = (json["streams"] as? [[String: Any]])?.first else { return stream }
        stream.sampleRate = Int(first["sample_rate"] as? String ?? "") ?? 44_100
        stream.channels = first["channels"] as? Int ?? 2
        let bits = first["bits_per_sample"] as? Int ?? 0
        let raw = Int(first["bits_per_raw_sample"] as? String ?? "") ?? 0
        stream.bitsPerSample = max(bits, raw, 16)
        if let format = first["sample_fmt"] as? String, format.hasPrefix("s32") || format.hasPrefix("flt") || format.hasPrefix("dbl") {
            stream.bitsPerSample = max(stream.bitsPerSample, 24)
        }
        return stream
    }

    private static func compressAudio(_ work: Work) async throws {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw ProcessError.missingTool("ffmpeg") }
        let info = try await MediaInfo.probe(work.source)
        guard info.hasAudio else { throw GeneralToolFailure("This file has no audio track.") }
        let ext = work.output.pathExtension.lowercased()
        let strong = work.request.strength == .strong
        let stream = await probeAudio(work.source)
        let keepsArtwork = ["mp3", "m4a", "flac"].contains(ext)
        var mapping = ["-map", "0:a:0"]
        if keepsArtwork { mapping += ["-map", "0:v?", "-c:v", "copy"] }
        mapping += ["-map_metadata", "0"]

        func run(_ codec: [String]) async throws -> Int64 {
            try await MediaConverter.run(ffmpeg, ["-y", "-hide_banner", "-nostdin", "-i", work.source.path] + mapping + codec
                                         + [work.output.path],
                                         duration: info.duration, context: work.context, progressRange: 0.05...0.95)
            return GeneralSizeText.bytes(of: work.output)
        }

        switch FileFormat.detect(work.source) {
        case .mp3, .m4a, .ogg, .opus, .wma:
            let codecName: String
            var minimum = 16
            switch ext {
            case "mp3": codecName = "libmp3lame"; minimum = 8
            case "ogg": codecName = "libvorbis"; minimum = 32
            case "opus": codecName = "libopus"; minimum = 6
            case "wma": codecName = "wmav2"; minimum = 24
            default: codecName = ToolPaths.ffmpegHasAudioToolbox ? "aac_at" : "aac"; minimum = 24
            }
            // Never ask for more than the source carries, so the copy always shrinks.
            let sourceKbps = info.duration > 0 ? Double(work.originalSize) * 8 / info.duration / 1000 : 320
            var kbps: Int
            if work.hasTarget {
                guard info.duration > 0 else { throw GeneralToolFailure(CompressionText.tooSmallForDuration) }
                kbps = Int(Double(work.limit) * 8 * 0.95 / info.duration / 1000)
                kbps = min(kbps, Int(sourceKbps * 0.95))
                guard kbps >= minimum else { throw GeneralToolFailure(CompressionText.tooSmallForDuration) }
            } else {
                let preset = ext == "opus" ? (strong ? 64 : 96) : (strong ? 96 : 128)
                kbps = max(minimum, min(preset, Int(sourceKbps * 0.8)))
            }
            var size = try await run(["-c:a", codecName, "-b:a", "\(kbps)k"])
            if work.hasTarget && size > work.limit {
                kbps = Int(Double(kbps) * Double(work.limit) / Double(size) * 0.93)
                guard kbps >= minimum else { throw GeneralToolFailure(CompressionText.unreachable(size)) }
                size = try await run(["-c:a", codecName, "-b:a", "\(kbps)k"])
                if size > work.limit { throw GeneralToolFailure(CompressionText.unreachable(size)) }
            }
        case .wav, .aiff:
            let pcm = ext == "wav" ? "pcm_s16le" : "pcm_s16be"
            let adpcm = ext == "wav" ? "adpcm_ima_wav" : "adpcm_ima_qt"
            var ladder: [[String]] = []
            let highResolution = stream.bitsPerSample > 16 || stream.sampleRate > 48_000
            if work.hasTarget {
                if highResolution { ladder.append(["-c:a", pcm, "-ar", "\(min(stream.sampleRate, 48_000))"]) }
                ladder += [["-c:a", adpcm],
                           ["-c:a", adpcm, "-ar", "32000"],
                           ["-c:a", adpcm, "-ar", "22050"],
                           ["-c:a", adpcm, "-ar", "16000", "-ac", "1"],
                           ["-c:a", adpcm, "-ar", "8000", "-ac", "1"]]
            } else if strong {
                ladder = [["-c:a", adpcm, "-ar", "\(min(stream.sampleRate, 32_000))"]]
            } else {
                ladder = [highResolution ? ["-c:a", pcm, "-ar", "\(min(stream.sampleRate, 48_000))"] : ["-c:a", adpcm]]
            }
            try await runLadder(work, ladder, run: run)
        case .flac:
            let rate = min(stream.sampleRate, 44_100)
            var ladder: [[String]] = []
            if work.hasTarget {
                ladder = [["-c:a", "flac", "-compression_level", "12"],
                          ["-c:a", "flac", "-compression_level", "12", "-sample_fmt", "s16", "-ar", "\(rate)"],
                          ["-c:a", "flac", "-compression_level", "12", "-sample_fmt", "s16", "-ar", "32000"],
                          ["-c:a", "flac", "-compression_level", "12", "-sample_fmt", "s16", "-ar", "22050"],
                          ["-c:a", "flac", "-compression_level", "12", "-sample_fmt", "s16", "-ar", "16000", "-ac", "1"]]
            } else if strong {
                ladder = [["-c:a", "flac", "-compression_level", "12", "-sample_fmt", "s16", "-ar", "\(rate)"]]
            } else {
                ladder = [["-c:a", "flac", "-compression_level", "12"]]
            }
            try await runLadder(work, ladder, run: run)
        default:
            throw GeneralToolFailure("This file type is not supported.")
        }
        guard let output = try? await MediaInfo.probe(work.output), output.hasAudio,
              info.duration <= 0 || abs(output.duration - info.duration) <= max(0.5, info.duration * 0.03) else {
            throw GeneralToolFailure("The compressed audio could not be verified.")
        }
    }

    private static func runLadder(_ work: Work, _ ladder: [[String]], run: ([String]) async throws -> Int64) async throws {
        var smallest = Int64.max
        for codec in ladder {
            try work.context.checkCancelled()
            let size = try await run(codec)
            smallest = min(smallest, size)
            if size <= work.limit { return }
        }
        if work.hasTarget { throw GeneralToolFailure(CompressionText.unreachable(smallest)) }
    }

    // MARK: - PDF

    private static func compressPDF(_ work: Work) async throws {
        guard let source = PDFDocument(url: work.source), !source.isLocked else { throw DocumentError.unreadablePDF }
        let pageCount = source.pageCount
        guard pageCount > 0 else { throw GeneralToolFailure("This PDF has no pages.") }
        guard let gs = ToolPaths.find("gs") else {
            // Quartz fallback: JPEG images at screen resolution.
            let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
            guard source.write(to: work.output, withOptions: options) else { throw GeneralToolFailure("Could not create the compressed PDF.") }
            try verifyPDF(work.output, pageCount: pageCount)
            return
        }
        var attempts: [[String]] = [[work.request.strength == .balanced ? "-dPDFSETTINGS=/ebook" : "-dPDFSETTINGS=/screen"]]
        if work.hasTarget {
            if work.request.strength == .balanced { attempts.append(["-dPDFSETTINGS=/screen"]) }
            for resolution in [96, 72, 50, 36] {
                attempts.append(["-dPDFSETTINGS=/screen",
                                 "-dDownsampleColorImages=true", "-dColorImageDownsampleType=/Bicubic", "-dColorImageResolution=\(resolution)",
                                 "-dColorImageDownsampleThreshold=1.0",
                                 "-dDownsampleGrayImages=true", "-dGrayImageDownsampleType=/Bicubic", "-dGrayImageResolution=\(resolution)",
                                 "-dGrayImageDownsampleThreshold=1.0",
                                 "-dDownsampleMonoImages=true", "-dMonoImageResolution=\(resolution * 2)"])
            }
        }
        var smallest = Int64.max
        let candidate = work.scratch.appendingPathComponent("attempt.pdf")
        for (index, settings) in attempts.enumerated() {
            try work.context.checkCancelled()
            try? FileManager.default.removeItem(at: candidate)
            do {
                try await work.context.runner.run(gs, ["-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=pdfwrite",
                                                       "-dCompatibilityLevel=1.5", "-dDetectDuplicateImages=true",
                                                       "-dCompressFonts=true"] + settings
                                                  + ["-sOutputFile=\(candidate.path)", work.source.path])
            } catch ProcessError.cancelled {
                throw ProcessError.cancelled
            } catch {
                throw GeneralToolFailure("Could not create the compressed PDF.")
            }
            try verifyPDF(candidate, pageCount: pageCount)
            work.context.progress(Double(index + 1) / Double(attempts.count + 1))
            let size = GeneralSizeText.bytes(of: candidate)
            smallest = min(smallest, size)
            if size <= work.limit || !work.hasTarget {
                try? FileManager.default.removeItem(at: work.output)
                try FileManager.default.moveItem(at: candidate, to: work.output)
                return
            }
        }
        throw GeneralToolFailure(CompressionText.unreachable(smallest))
    }

    private static func verifyPDF(_ url: URL, pageCount: Int) throws {
        guard let document = PDFDocument(url: url), document.pageCount == pageCount,
              document.page(at: 0) != nil else { throw GeneralToolFailure(CompressionText.pdfUnverified) }
    }
}
