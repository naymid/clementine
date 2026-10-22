import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageError: LocalizedError {
    case unreadable(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Could not read the image \(name)."
        case .writeFailed(let detail): return detail
        }
    }
}

/// Shared image loading and saving built on ImageIO.
enum ImageIOHelpers {
    struct LoadedImage {
        var image: CGImage
        var properties: [CFString: Any]
        var hasAlpha: Bool {
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: return false
            default: return true
            }
        }
    }

    /// Loads the first frame, applying EXIF orientation so pixels are upright.
    static func load(_ url: URL, maxPixel: Int? = nil) throws -> LoadedImage {
        if url.pathExtension.lowercased() == "svg" { return try loadSVG(url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw ImageError.unreadable(url.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = max(width, height)
        let limit = min(maxPixel ?? longest, longest)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(limit, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageError.unreadable(url.lastPathComponent)
        }
        var cleaned = properties
        cleaned[kCGImagePropertyOrientation] = 1
        if var tiff = cleaned[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            cleaned[kCGImagePropertyTIFFDictionary] = tiff
        }
        cleaned[kCGImagePropertyPixelWidth] = image.width
        cleaned[kCGImagePropertyPixelHeight] = image.height
        return LoadedImage(image: image, properties: cleaned)
    }

    private static func loadSVG(_ url: URL) throws -> LoadedImage {
        guard let image = NSImage(contentsOf: url) else { throw ImageError.unreadable(url.lastPathComponent) }
        var size = image.size
        if size.width < 1 || size.height < 1 { size = NSSize(width: 1024, height: 1024) }
        // Rasterize small vector art at a useful resolution.
        let scale = max(1, 2048 / max(size.width, size.height))
        let pixelSize = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw ImageError.unreadable(url.lastPathComponent)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: pixelSize))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = rep.cgImage else { throw ImageError.unreadable(url.lastPathComponent) }
        return LoadedImage(image: cgImage, properties: [:])
    }

    static func size(of url: URL) -> CGSize? {
        if url.pathExtension.lowercased() == "svg" { return NSImage(contentsOf: url)?.size }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Draws the image over a solid background, removing transparency.
    static func flatten(_ image: CGImage, background: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Scales so the longest edge is at most `longestEdge` pixels.
    static func resize(_ image: CGImage, longestEdge: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > longestEdge else { return image }
        let scale = Double(longestEdge) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func utType(for format: FileFormat) -> UTType? {
        switch format {
        case .jpg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        case .bmp: return .bmp
        case .avif: return UTType("public.avif")
        case .gif: return .gif
        default: return nil
        }
    }

    /// Writes `image` with ImageIO. `quality` is 0...1 for lossy formats.
    static func write(_ image: CGImage, to url: URL, format: FileFormat, quality: Double?,
                      properties: [CFString: Any]? = nil) throws {
        guard let type = utType(for: format) else { throw ImageError.writeFailed("ImageIO could not create the output image.") }
        var output = image
        if format == .jpg || format == .bmp {
            output = flatten(image)
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageError.writeFailed("ImageIO could not create the output image.")
        }
        var options: [CFString: Any] = properties ?? [:]
        // Keep only metadata the destination understands; ImageIO ignores the rest.
        options[kCGImagePropertyPixelWidth] = nil
        options[kCGImagePropertyPixelHeight] = nil
        options[kCGImagePropertyOrientation] = 1
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, output, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageError.writeFailed("ImageIO could not finish the conversion.")
        }
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.9) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, flatten(image), [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func nsImage(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
