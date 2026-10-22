import AppKit
import ImageIO

enum ImageConverter {
    static func quality(_ quality: ConversionQuality, for format: FileFormat) -> Double {
        switch (format, quality) {
        case (.avif, .smaller), (.heic, .smaller): return 0.5
        case (.avif, .balanced), (.heic, .balanced): return 0.7
        case (.avif, .higher), (.heic, .higher): return 0.88
        case (_, .smaller): return 0.62
        case (_, .balanced): return 0.82
        case (_, .higher): return 0.94
        }
    }

    static func convert(_ source: URL, from format: FileFormat, to target: FileFormat,
                        options: FormatOptions, context: JobContext) async throws -> [URL] {
        let output = FileNaming.output(beside: source, extension: target.outputExtension)
        context.progress(0.1)
        switch target {
        case .pdf:
            try writePDF(images: [source], to: output)
        case .docx:
            let loaded = try ImageIOHelpers.load(source)
            try DocxWriter.write(images: [loaded.image], to: output)
        case .webp:
            try await writeWebP(source: source, format: format, to: output, options: options, context: context)
        default:
            let loaded = try ImageIOHelpers.load(source)
            context.progress(0.5)
            let lossy: Double? = [.jpg, .heic, .avif].contains(target) ? quality(options.quality, for: target) : nil
            let properties = options.preserveMetadata ? loaded.properties : nil
            try ImageIOHelpers.write(loaded.image, to: output, format: target, quality: lossy, properties: properties)
        }
        return [output]
    }

    static func writeWebP(source: URL, format: FileFormat, to output: URL, options: FormatOptions,
                          context: JobContext, qualityOverride: Double? = nil, resize: Int? = nil) async throws {
        let q = Int(((qualityOverride ?? quality(options.quality, for: .webp)) * 100).rounded())
        let scratch = try FileNaming.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var input = source
        // cwebp reads PNG, JPEG, TIFF and WebP; anything else goes through a PNG first.
        if ![.png, .jpg, .tiff, .webp].contains(format) || resize != nil {
            var loaded = try ImageIOHelpers.load(source)
            if let resize { loaded.image = ImageIOHelpers.resize(loaded.image, longestEdge: resize) }
            input = scratch.appendingPathComponent("input.png")
            try ImageIOHelpers.write(loaded.image, to: input, format: .png, quality: nil, properties: options.preserveMetadata ? loaded.properties : nil)
        }
        context.progress(0.4)
        if let cwebp = ToolPaths.cwebp {
            var arguments = ["-quiet", "-q", "\(q)", "-m", "6", "-mt", "-sharp_yuv"]
            arguments += ["-metadata", options.preserveMetadata ? "all" : "none"]
            arguments += [input.path, "-o", output.path]
            try await context.runner.run(cwebp, arguments)
        } else if let ffmpeg = ToolPaths.ffmpeg {
            try await context.runner.run(ffmpeg, ["-y", "-v", "error", "-i", input.path, "-c:v", "libwebp", "-quality", "\(q)", "-frames:v", "1", output.path])
        } else {
            throw ProcessError.missingTool("webp")
        }
    }

    /// One page per image, each page sized to its image.
    static func writePDF(images: [URL], to output: URL, uniformWidth: Bool = false) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else {
            throw ImageError.writeFailed("Could not create the PDF.")
        }
        var loadedImages: [CGImage] = []
        for url in images { loadedImages.append(try ImageIOHelpers.load(url).image) }
        let targetWidth = loadedImages.map { CGFloat($0.width) }.min() ?? 612
        for image in loadedImages {
            var size = CGSize(width: image.width, height: image.height)
            // Express pixels as points at 144 ppi so photos land at a sensible page size.
            size = CGSize(width: size.width / 2, height: size.height / 2)
            if uniformWidth {
                let scale = (targetWidth / 2) / size.width
                size = CGSize(width: size.width * scale, height: size.height * scale)
            }
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            context.interpolationQuality = .high
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
    }
}
