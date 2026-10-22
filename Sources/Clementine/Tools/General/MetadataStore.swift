import AppKit
import CryptoKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// One readable metadata value.
struct MetadataField: Identifiable, Hashable {
    /// Image: XMP path ("exif:GPSLatitude"); media: "format:title" or "stream:1:handler_name"; PDF: "pdf:Title".
    let id: String
    var section: String
    var label: String
    var value: String
    var editable = false
    var removable = true
    var sensitive = false
}

struct MetadataSection: Identifiable {
    var id: String { title }
    var title: String
    var symbol: String
    var fields: [MetadataField]
}

enum MetadataFileKind { case image, media, pdf }

struct MetadataReport {
    var kind: MetadataFileKind
    var sections: [MetadataSection]
    var fields: [MetadataField] { sections.flatMap(\.fields) }
    var isEmpty: Bool { sections.allSatisfy { $0.fields.isEmpty } }
}

/// Pending edits for one file.
struct MetadataChanges: Equatable {
    var removed: Set<String> = []
    var edits: [String: String] = [:]
    var isEmpty: Bool { removed.isEmpty && edits.isEmpty }
}

enum MetadataText {
    static let note = "Remove metadata now and save a new file. Photo cleanup includes private blocks that cannot be removed individually. The original stays unchanged."
    static let empty = "No readable metadata found."
    static let pixelsChanged = "Image pixels changed; the output was rejected."
    static func notSaved(_ name: String) -> String {
        "This format could not save the change to \(name). The original file is unchanged."
    }
}

/// Reads and writes metadata for images (ImageIO, lossless), audio/video (ffmpeg stream copy) and PDFs (PDFKit).
enum MetadataStore {
    static func kind(of url: URL) -> MetadataFileKind? {
        guard let format = FileFormat.detect(url) else { return nil }
        if format == .pdf { return .pdf }
        if format.family == .audio || format.family == .video { return .media }
        if format.family == .image { return .image }
        return nil
    }

    static func read(_ url: URL) async throws -> MetadataReport {
        switch kind(of: url) {
        case .image: return try ImageMetadataIO.read(url)
        case .media: return try await MediaMetadataIO.read(url)
        case .pdf: return try PDFMetadataIO.read(url)
        case nil: throw GeneralToolFailure("This file type is not supported.")
        }
    }

    /// Removes everything removable and saves "<name>-clean".
    static func removeAll(_ url: URL, context: JobContext) async throws -> URL {
        let output = FileNaming.output(beside: url, suffix: "-clean", extension: url.pathExtension)
        try await write(url, to: output, context: context) { scratch in
            switch kind(of: url) {
            case .image: try ImageMetadataIO.removeAll(url, to: scratch)
            case .media: try await MediaMetadataIO.write(url, to: scratch, changes: nil, context: context)
            case .pdf: try PDFMetadataIO.write(url, to: scratch, changes: nil)
            case nil: throw GeneralToolFailure("This file type is not supported.")
            }
        }
        return output
    }

    /// Applies field removals and edits and saves "<name>-edited".
    static func apply(_ changes: MetadataChanges, to url: URL, context: JobContext) async throws -> URL {
        let output = FileNaming.output(beside: url, suffix: "-edited", extension: url.pathExtension)
        try await write(url, to: output, context: context) { scratch in
            switch kind(of: url) {
            case .image: try ImageMetadataIO.apply(changes, url, to: scratch)
            case .media: try await MediaMetadataIO.write(url, to: scratch, changes: changes, context: context)
            case .pdf: try PDFMetadataIO.write(url, to: scratch, changes: changes)
            case nil: throw GeneralToolFailure("This file type is not supported.")
            }
        }
        return output
    }

    /// Writes into a scratch file first, so a failed or rejected write never leaves a partial file.
    private static func write(_ url: URL, to output: URL, context: JobContext, _ body: (URL) async throws -> Void) async throws {
        let scratchDirectory = try FileNaming.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        let scratch = scratchDirectory.appendingPathComponent("output." + url.pathExtension)
        context.progress(0.1)
        try await body(scratch)
        try context.checkCancelled()
        guard FileManager.default.fileExists(atPath: scratch.path) else { throw ConversionError.noOutput }
        try FileManager.default.moveItem(at: scratch, to: output)
        context.progress(1)
    }

    // MARK: Shared formatting

    /// "BodySerialNumber" → "Body Serial Number".
    static func words(_ name: String) -> String {
        var result = ""
        var previous: Character?
        for character in name {
            if let previous, character.isUppercase, previous.isLowercase || previous.isNumber { result.append(" ") }
            result.append(character)
            previous = character
        }
        return result.prefix(1).uppercased() + result.dropFirst()
    }
}

// MARK: - Images

enum ImageMetadataIO {
    /// Technical tags that describe the pixels rather than the photo; not listed and always kept.
    static let technical: Set<String> = [
        "tiff:Orientation", "exif:PixelXDimension", "exif:PixelYDimension", "exif:ColorSpace", "tiff:TileWidth", "tiff:TileLength",
        "tiff:Compression", "tiff:PhotometricInterpretation", "tiff:ResolutionUnit", "tiff:XResolution", "tiff:YResolution",
        "tiff:BitsPerSample", "tiff:SamplesPerPixel", "tiff:PlanarConfiguration", "tiff:ImageWidth", "tiff:ImageLength",
        "exif:ExifVersion", "exif:FlashpixVersion", "exif:ComponentsConfiguration", "tiff:YCbCrPositioning",
    ]

    static let editablePaths: Set<String> = [
        "dc:title", "dc:description", "dc:creator", "dc:rights", "dc:subject", "tiff:Artist", "tiff:Copyright",
        "tiff:ImageDescription", "exif:UserComment", "tiff:Software", "xmp:CreatorTool", "photoshop:Headline",
        "photoshop:Credit", "photoshop:Source", "photoshop:Instructions", "photoshop:City", "photoshop:State",
        "photoshop:Country", "Iptc4xmpCore:Location", "xmp:Label",
    ]

    static let sensitivePaths: Set<String> = [
        "exifEX:BodySerialNumber", "exifEX:LensSerialNumber", "exifEX:CameraOwnerName", "aux:SerialNumber", "aux:OwnerName",
        "aux:LensSerialNumber", "tiff:Software", "xmp:CreatorTool", "tiff:HostComputer", "tiff:Artist", "dc:creator",
        "photoshop:City", "photoshop:State", "photoshop:Country", "Iptc4xmpCore:Location", "Iptc4xmpCore:CountryCode",
        "Iptc4xmpExt:LocationCreated", "Iptc4xmpExt:LocationShown", "exif:UserComment",
    ]

    static let labels: [String: String] = [
        "dc:title": "Title", "dc:description": "Description", "dc:creator": "Creator", "dc:rights": "Copyright",
        "dc:subject": "Keywords", "tiff:Make": "Camera Make", "tiff:Model": "Camera Model", "xmp:CreatorTool": "Software",
        "exifEX:BodySerialNumber": "Camera Serial Number", "exifEX:CameraOwnerName": "Camera Owner",
        "aux:SerialNumber": "Camera Serial Number", "aux:OwnerName": "Camera Owner", "exif:GPSLatitude": "Latitude",
        "exif:GPSLongitude": "Longitude", "exif:GPSAltitude": "Altitude", "exif:GPSAltitudeRef": "Altitude Reference",
        "exif:ISOSpeedRatings": "ISO Speed", "exifEX:PhotographicSensitivity": "Sensitivity", "exif:FNumber": "Aperture (f-number)",
        "photoshop:DateCreated": "Date Created", "exif:DateTimeOriginal": "Date Taken", "xmp:CreateDate": "Date Created",
        "xmp:ModifyDate": "Date Modified", "tiff:DateTime": "Date Modified",
    ]

    static let sectionOrder = ["GPS Location", "Exif", "TIFF", "IPTC", "Exif Aux", "Apple", "XMP", "PNG Text"]
    static let sectionSymbols: [String: String] = [
        "GPS Location": "mappin.and.ellipse", "Exif": "camera", "TIFF": "photo", "IPTC": "text.quote", "Exif Aux": "camera.aperture",
        "Apple": "apple.logo", "XMP": "chevron.left.forwardslash.chevron.right", "PNG Text": "text.alignleft",
    ]

    static let pngTextKeys: [CFString] = [
        kCGImagePropertyPNGTitle, kCGImagePropertyPNGAuthor, kCGImagePropertyPNGDescription, kCGImagePropertyPNGCopyright,
        kCGImagePropertyPNGSoftware, kCGImagePropertyPNGComment, kCGImagePropertyPNGCreationTime, kCGImagePropertyPNGDisclaimer,
        kCGImagePropertyPNGWarning, kCGImagePropertyPNGSource,
    ]

    static func section(prefix: String, name: String) -> String {
        switch prefix {
        case "exif" where name.hasPrefix("GPS"): return "GPS Location"
        case "exif", "exifEX": return "Exif"
        case "tiff": return "TIFF"
        case "aux": return "Exif Aux"
        case "photoshop", "Iptc4xmpCore", "Iptc4xmpExt": return "IPTC"
        default: return "XMP"
        }
    }

    static func read(_ url: URL) throws -> MetadataReport {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw GeneralToolFailure("Could not read the image.")
        }
        var fields: [MetadataField] = []
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            for tag in CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] ?? [] {
                guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?, let name = CGImageMetadataTagCopyName(tag) as String?,
                      prefix != "iio" else { continue }
                let path = "\(prefix):\(name)"
                if technical.contains(path) { continue }
                let value = displayValue(tag, path: path)
                guard !value.isEmpty else { continue }
                let isGPS = prefix == "exif" && name.hasPrefix("GPS")
                fields.append(MetadataField(id: path, section: section(prefix: prefix, name: name),
                                            label: labels[path] ?? MetadataStore.words(name.hasPrefix("GPS") ? String(name.dropFirst(3)) : name),
                                            value: value, editable: editablePaths.contains(path) && isText(tag),
                                            removable: true, sensitive: isGPS || sensitivePaths.contains(path)))
            }
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        // Apple's maker notes have no XMP path: listed, but only Remove All clears them.
        if let apple = properties[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any], !apple.isEmpty {
            fields.append(MetadataField(id: "apple:MakerNote", section: "Apple", label: "Apple camera data",
                                        value: "\(apple.count) private values", editable: false, removable: false, sensitive: true))
        }
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            for key in pngTextKeys {
                guard let value = png[key] else { continue }
                let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                fields.append(MetadataField(id: "png:\(key)", section: "PNG Text", label: MetadataStore.words(key as String), value: text,
                                            editable: false, removable: true,
                                            sensitive: [kCGImagePropertyPNGAuthor, kCGImagePropertyPNGSoftware].contains(key)))
            }
        }
        let grouped = Dictionary(grouping: fields, by: \.section)
        let sections = sectionOrder.compactMap { title -> MetadataSection? in
            guard let fields = grouped[title], !fields.isEmpty else { return nil }
            return MetadataSection(title: title, symbol: sectionSymbols[title] ?? "tag",
                                   fields: fields.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending })
        }
        return MetadataReport(kind: .image, sections: sections)
    }

    private static func isText(_ tag: CGImageMetadataTag) -> Bool {
        switch CGImageMetadataTagGetType(tag) {
        case .string, .alternateText, .arrayOrdered, .arrayUnordered: return true
        default: return false
        }
    }

    static func displayValue(_ tag: CGImageMetadataTag, path: String = "") -> String {
        guard let value = CGImageMetadataTagCopyValue(tag) else { return "" }
        switch CGImageMetadataTagGetType(tag) {
        case .arrayOrdered, .arrayUnordered, .alternateArray, .alternateText:
            let items = (value as? [CGImageMetadataTag] ?? []).map { displayValue($0) }.filter { !$0.isEmpty }
            return items.joined(separator: ", ")
        case .structure:
            let items = (value as? [String: CGImageMetadataTag] ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.key): \(displayValue($0.value))" }
            return items.joined(separator: ", ")
        default:
            let text = "\(value)"
            if path == "exif:GPSLatitude" || path == "exif:GPSLongitude", let degrees = coordinate(text) { return degrees }
            return rational(text) ?? text
        }
    }

    /// "40,42.768N" → "40.712800° N".
    private static func coordinate(_ text: String) -> String? {
        guard let direction = text.last, "NSEW".contains(direction) else { return nil }
        let parts = text.dropLast().split(separator: ",").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        var degrees = parts[0]
        if parts.count > 1 { degrees += parts[1] / 60 }
        if parts.count > 2 { degrees += parts[2] / 3600 }
        return String(format: "%.6f° %@", degrees, String(direction))
    }

    /// "89/50" → "1.78".
    private static func rational(_ text: String) -> String? {
        let parts = text.split(separator: "/")
        guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 else { return nil }
        let value = numerator / denominator
        return value == value.rounded() ? String(Int(value)) : String(format: "%.4g", value)
    }

    // MARK: Writing

    private static func source(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw GeneralToolFailure("Could not read the image.")
        }
        return source
    }

    private static func orientation(_ source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyOrientation] as? Int ?? 1
    }

    private static func orientationOnlyMetadata(_ orientation: Int) -> CGMutableImageMetadata {
        let metadata = CGImageMetadataCreateMutable()
        if orientation != 1 {
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation,
                                                         orientation as CFNumber)
        }
        return metadata
    }

    static func removeAll(_ url: URL, to output: URL) throws {
        let format = FileFormat.detect(url)
        let source = try source(url)
        let orientation = orientation(source)
        switch format {
        case .jpg:
            try copySource(source, metadata: orientationOnlyMetadata(orientation), excludeGPS: true, excludeXMP: true, to: output)
        case .png where orientation == 1:
            try MetadataContainers.stripPNG(try Data(contentsOf: url)).write(to: output)
        case .heic, .avif:
            var bytes = [UInt8](try Data(contentsOf: url))
            try MetadataContainers.neutralizeHEIFMetadata(&bytes)
            try Data(bytes).write(to: output)
        case .webp:
            var data = try MetadataContainers.stripWebP(try Data(contentsOf: url))
            if orientation != 1 {
                // Keep the rotation: a fresh EXIF chunk with only the orientation.
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
                let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 1
                let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 1
                let blobs = MetadataContainers.exifAndXMP(for: orientationOnlyMetadata(orientation), width: width, height: height)
                data = try MetadataContainers.webP(data, exif: blobs.exif, xmp: nil, width: width, height: height,
                                                   hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false)
            }
            try data.write(to: output)
        default:
            // PNG with a rotation tag, and TIFF: lossless re-encode with only the orientation.
            try reencode(source, format: format ?? .png, metadata: orientationOnlyMetadata(orientation), pngText: nil, to: output)
        }
        try verifyPixels(url, output, lossless: true)
        try verifyClean(output, name: url.lastPathComponent)
    }

    static func apply(_ changes: MetadataChanges, _ url: URL, to output: URL) throws {
        let format = FileFormat.detect(url)
        let source = try source(url)
        guard let original = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let metadata = CGImageMetadataCreateMutableCopy(original) else {
            throw GeneralToolFailure(MetadataText.notSaved(url.lastPathComponent))
        }
        for path in changes.removed where !path.hasPrefix("png:") && !path.hasPrefix("apple:") {
            CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        }
        for (path, value) in changes.edits where !changes.removed.contains(path) {
            setValue(value, path: path, in: metadata, original: original)
        }
        let remainingGPS = (CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] ?? []).contains {
            (CGImageMetadataTagCopyPrefix($0) as String?) == "exif" && ((CGImageMetadataTagCopyName($0) as String?) ?? "").hasPrefix("GPS")
        }
        var lossless = true
        switch format {
        case .jpg:
            try copySource(source, metadata: metadata, excludeGPS: !remainingGPS, excludeXMP: false, to: output)
        case .heic:
            // Clear the old Exif/XMP items first; ImageIO then writes the edited set.
            var bytes = [UInt8](try Data(contentsOf: url))
            try MetadataContainers.neutralizeHEIFMetadata(&bytes)
            guard let cleaned = CGImageSourceCreateWithData(Data(bytes) as CFData, nil) else {
                throw GeneralToolFailure(MetadataText.notSaved(url.lastPathComponent))
            }
            try copySource(cleaned, metadata: metadata, excludeGPS: !remainingGPS, excludeXMP: false, to: output)
        case .webp:
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 1
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 1
            let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
            let blobs = MetadataContainers.exifAndXMP(for: metadata, width: width, height: height)
            try MetadataContainers.webP(try Data(contentsOf: url), exif: blobs.exif, xmp: blobs.xmp,
                                        width: width, height: height, hasAlpha: hasAlpha).write(to: output)
        case .avif:
            // ImageIO cannot rewrite AVIF metadata in place: high-quality re-encode.
            lossless = false
            try reencode(source, format: .avif, metadata: metadata, pngText: nil, to: output)
        default:
            var pngText: [CFString: Any]?
            if format == .png,
               let png = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
                pngText = png.filter { key, _ in pngTextKeys.contains(key) && !changes.removed.contains("png:\(key)") }
            }
            try reencode(source, format: format ?? .png, metadata: metadata, pngText: pngText, to: output)
        }
        try verifyPixels(url, output, lossless: lossless)
        // Every removed field must really be gone.
        if let written = try? read(output) {
            let remaining = Set(written.fields.map(\.id))
            let survivors = changes.removed.filter { remaining.contains($0) && !$0.hasPrefix("apple:") }
            if let first = survivors.first {
                throw GeneralToolFailure(MetadataText.notSaved(written.fields.first { $0.id == first }?.label ?? first))
            }
        }
    }

    /// Sets a text value, keeping the tag's structure (alternate text, keyword arrays).
    private static func setValue(_ value: String, path: String, in metadata: CGMutableImageMetadata, original: CGImageMetadata) {
        let existing = CGImageMetadataCopyTagWithPath(original, nil, path as CFString)
        let type = existing.map(CGImageMetadataTagGetType) ?? .string
        let parts = path.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        if type == .arrayOrdered || type == .arrayUnordered,
           let namespace = existing.flatMap({ CGImageMetadataTagCopyNamespace($0) as String? }) ?? namespaceURI(for: parts[0]) {
            // Keywords and creators: a comma-separated list becomes an XMP array.
            let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let tag = CGImageMetadataTagCreate(namespace as CFString, parts[0] as CFString, parts[1] as CFString, type, items as CFArray) {
                CGImageMetadataSetTagWithPath(metadata, nil, path as CFString, tag)
                return
            }
        }
        // ImageIO turns a plain string into the right shape (alternate text for dc:title, for example).
        CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString)
    }

    private static func namespaceURI(for prefix: String) -> String? {
        switch prefix {
        case "dc": return kCGImageMetadataNamespaceDublinCore as String
        case "xmp": return kCGImageMetadataNamespaceXMPBasic as String
        case "tiff": return kCGImageMetadataNamespaceTIFF as String
        case "exif": return kCGImageMetadataNamespaceExif as String
        case "photoshop": return kCGImageMetadataNamespacePhotoshop as String
        case "Iptc4xmpCore": return kCGImageMetadataNamespaceIPTCCore as String
        default: return nil
        }
    }

    private static func copySource(_ source: CGImageSource, metadata: CGImageMetadata, excludeGPS: Bool, excludeXMP: Bool, to output: URL) throws {
        guard let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
            throw GeneralToolFailure("ImageIO could not create the output image.")
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: excludeGPS,
            kCGImageMetadataShouldExcludeXMP: excludeXMP,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            throw GeneralToolFailure((error?.takeRetainedValue()).map { "\($0.localizedDescription)" } ?? "ImageIO could not finish the image.")
        }
    }

    /// Decodes and re-encodes with exactly the given metadata. Lossless for PNG and TIFF.
    private static func reencode(_ source: CGImageSource, format: FileFormat, metadata: CGImageMetadata, pngText: [CFString: Any]?,
                                 to output: URL) throws {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let type = ImageIOHelpers.utType(for: format),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw GeneralToolFailure("ImageIO could not create the output image.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        // Orientation is display information, not personal data: always carried over.
        var options: [CFString: Any] = [kCGImagePropertyOrientation: properties[kCGImagePropertyOrientation] as? Int ?? 1]
        if format == .tiff, let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let compression = tiff[kCGImagePropertyTIFFCompression] {
            options[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: compression]
        }
        if let pngText, !pngText.isEmpty { options[kCGImagePropertyPNGDictionary] = pngText }
        if format == .avif || format == .heic { options[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw GeneralToolFailure("ImageIO could not finish the image.") }
    }

    // MARK: Verification

    /// Compares decoded pixels (lossless paths) or at least dimensions (re-encoded AVIF).
    static func verifyPixels(_ original: URL, _ output: URL, lossless: Bool) throws {
        guard let a = CGImageSourceCreateWithURL(original as CFURL, nil), let b = CGImageSourceCreateWithURL(output as CFURL, nil),
              let first = CGImageSourceCreateImageAtIndex(a, 0, nil), let second = CGImageSourceCreateImageAtIndex(b, 0, nil) else {
            throw GeneralToolFailure("The image could not be verified. No output was saved.")
        }
        guard first.width == second.width, first.height == second.height,
              orientation(a) == orientation(b) else { throw GeneralToolFailure(MetadataText.pixelsChanged) }
        guard lossless else { return }
        guard pixelHash(first) == pixelHash(second) else { throw GeneralToolFailure(MetadataText.pixelsChanged) }
    }

    /// SHA-256 of the pixels drawn into a fixed RGBA layout in the image's own color space.
    static func pixelHash(_ image: CGImage) -> String {
        let width = image.width, height = image.height
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        var buffer = [UInt16](repeating: 0, count: width * height * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 16,
                                          bytesPerRow: width * 8, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return UUID().uuidString }
        return buffer.withUnsafeBytes { SHA256.hash(data: $0).description }
    }

    /// After Remove All, nothing but technical tags may remain.
    private static func verifyClean(_ output: URL, name: String) throws {
        let report = try read(output)
        if let leftover = report.fields.first(where: { $0.removable }) {
            throw GeneralToolFailure(MetadataText.notSaved(leftover.label))
        }
        if let source = CGImageSourceCreateWithURL(output as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty {
            throw GeneralToolFailure(MetadataText.notSaved("GPS location"))
        }
    }
}

// MARK: - Audio and video

enum MediaMetadataIO {
    static let hiddenKeys: Set<String> = ["major_brand", "minor_version", "compatible_brands", "vendor_id", "handler_name"]
    static let editableKeys: Set<String> = [
        "title", "artist", "album", "album_artist", "comment", "description", "copyright", "genre", "date", "year", "composer",
        "lyrics", "synopsis", "show", "grouping", "keywords", "publisher", "performer", "author", "subtitle",
    ]
    static let labels: [String: String] = [
        "album_artist": "Album Artist", "creation_time": "Created", "encoder": "Encoder", "date": "Date",
        "com.apple.quicktime.location.ISO6709": "Location (ISO 6709)", "location": "Location",
        "com.apple.quicktime.make": "Camera Make", "com.apple.quicktime.model": "Camera Model",
        "com.apple.quicktime.software": "Software", "com.apple.quicktime.creationdate": "Date Created",
    ]

    static func isSensitive(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower.contains("location") || lower.contains("gps") || lower.hasSuffix("make") || lower.hasSuffix("model")
            || lower.contains("software") || lower == "encoder" || lower.contains("serial") || lower.contains("author")
            || lower == "artist" || lower.contains("owner")
    }

    static func label(_ key: String) -> String {
        if let label = labels[key] { return label }
        // "com.apple.quicktime.camera.lens_model" → "Lens Model"; "album_artist" → "Album Artist".
        let last = key.split(separator: ".").last.map(String.init) ?? key
        return MetadataStore.words(last.replacingOccurrences(of: "_", with: " ").capitalized.replacingOccurrences(of: " ", with: ""))
    }

    struct Probe {
        var format: [String: String] = [:]
        var streams: [(index: Int, type: String, tags: [String: String])] = []
        var chapterCount = 0
        var duration: Double = 0
    }

    static func probe(_ url: URL) async throws -> Probe {
        guard let ffprobe = ToolPaths.ffprobe else { throw ProcessError.missingTool("ffmpeg") }
        let result = try await ProcessRunner().run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams",
                                                             "-show_chapters", url.path])
        guard let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else { return Probe() }
        var probe = Probe()
        if let format = json["format"] as? [String: Any] {
            probe.format = (format["tags"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
            probe.duration = Double(format["duration"] as? String ?? "") ?? 0
        }
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let index = stream["index"] as? Int ?? probe.streams.count
            let type = stream["codec_type"] as? String ?? "data"
            probe.streams.append((index, type, (stream["tags"] as? [String: Any] ?? [:]).mapValues { "\($0)" }))
        }
        probe.chapterCount = (json["chapters"] as? [Any])?.count ?? 0
        return probe
    }

    /// Keys like "location-eng" duplicate "location"; they are hidden and removed together.
    private static func languageVariant(_ key: String, in keys: Set<String>) -> Bool {
        guard let dash = key.lastIndex(of: "-") else { return false }
        let suffix = key[key.index(after: dash)...]
        return suffix.count == 3 && suffix.allSatisfy(\.isLetter) && keys.contains(String(key[..<dash]))
    }

    /// Container bookkeeping rather than metadata. Matroska spells keys in capitals.
    private static func technicalKey(_ key: String, value: String) -> Bool {
        let lower = key.lowercased()
        if lower == "duration" || lower.hasPrefix("number_of_") || lower.hasPrefix("_statistics") || lower == "bps" { return true }
        if lower == "language" && (value == "und" || value.isEmpty) { return true }
        // ffmpeg's own muxer/encoder stamp ("Lavf", "Lavc…") identifies no one; stream copy rewrites it anyway.
        if lower == "encoder" && value.hasPrefix("Lav") { return true }
        return hiddenKeys.contains(lower)
    }

    static func read(_ url: URL) async throws -> MetadataReport {
        let probe = try await probe(url)
        var sections: [MetadataSection] = []
        let formatKeys = Set(probe.format.keys)
        var fileFields: [MetadataField] = probe.format.compactMap { key, value in
            guard !technicalKey(key, value: value), !languageVariant(key, in: formatKeys), !value.isEmpty else { return nil }
            return MetadataField(id: "format:\(key)", section: "File", label: label(key), value: value,
                                 editable: editableKeys.contains(key.lowercased()), removable: true, sensitive: isSensitive(key))
        }
        if probe.chapterCount > 0 {
            fileFields.append(MetadataField(id: "chapters", section: "File", label: "Chapters",
                                            value: "\(probe.chapterCount) chapter\(probe.chapterCount == 1 ? "" : "s")"))
        }
        if !fileFields.isEmpty {
            sections.append(MetadataSection(title: "File", symbol: "doc", fields: fileFields.sorted { $0.label < $1.label }))
        }
        var counters: [String: Int] = [:]
        for stream in probe.streams where stream.type != "data" {
            counters[stream.type, default: 0] += 1
            let keys = Set(stream.tags.keys)
            let fields: [MetadataField] = stream.tags.compactMap { key, value in
                guard !technicalKey(key, value: value), !languageVariant(key, in: keys), !value.isEmpty else { return nil }
                return MetadataField(id: "stream:\(stream.index):\(key)", section: "", label: label(key), value: value,
                                     editable: false, removable: true, sensitive: isSensitive(key))
            }
            guard !fields.isEmpty else { continue }
            let kind: String
            switch stream.type {
            case "video": kind = "Video Track"
            case "audio": kind = "Audio Track"
            case "subtitle": kind = "Subtitle Track"
            default: kind = "Track"
            }
            let count = probe.streams.filter { $0.type == stream.type }.count
            let title = count > 1 ? "\(kind) \(counters[stream.type] ?? 1)" : kind
            sections.append(MetadataSection(title: title, symbol: stream.type == "audio" ? "waveform" : stream.type == "video" ? "film" : "captions.bubble",
                                            fields: fields.map { var field = $0; field.section = title; return field }.sorted { $0.label < $1.label }))
        }
        return MetadataReport(kind: .media, sections: sections)
    }

    /// `changes == nil` removes everything; otherwise copies all metadata except removals, plus edits.
    static func write(_ url: URL, to output: URL, changes: MetadataChanges?, context: JobContext) async throws {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw ProcessError.missingTool("ffmpeg") }
        let probe = try await probe(url)
        let ext = url.pathExtension.lowercased()
        var arguments = ["-y", "-hide_banner", "-nostdin", "-i", url.path, "-map", "0", "-map", "-0:d?", "-c", "copy",
                         "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact"]
        // Output stream positions once data streams are dropped.
        let kept = probe.streams.filter { $0.type != "data" }
        if let changes {
            arguments += ["-map_metadata", "0", "-map_chapters", changes.removed.contains("chapters") ? "-1" : "0"]
            let formatKeys = Set(probe.format.keys)
            for id in changes.removed where id.hasPrefix("format:") {
                let key = String(id.dropFirst("format:".count))
                for variant in formatKeys where variant == key || (variant.hasPrefix(key + "-") && languageVariant(variant, in: [key])) {
                    arguments += ["-metadata", "\(variant)="]
                }
            }
            for (id, value) in changes.edits where id.hasPrefix("format:") && !changes.removed.contains(id) {
                arguments += ["-metadata", "\(id.dropFirst("format:".count))=\(value)"]
            }
            for id in changes.removed where id.hasPrefix("stream:") {
                let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
                guard parts.count == 3, let index = Int(parts[1]), let position = kept.firstIndex(where: { $0.index == index }) else { continue }
                arguments += ["-metadata:s:\(position)", "\(parts[2])="]
            }
            if ["mov", "mp4", "m4v"].contains(ext) { arguments += ["-movflags", "use_metadata_tags"] }
        } else {
            arguments += ["-map_metadata", "-1", "-map_chapters", "-1"]
            // Keep track languages: they are not personal, and players rely on them.
            for (position, stream) in kept.enumerated() {
                if let language = stream.tags["language"], language != "und" { arguments += ["-metadata:s:\(position)", "language=\(language)"] }
            }
        }
        arguments.append(output.path)
        try await MediaConverter.run(ffmpeg, arguments, duration: probe.duration, context: context, progressRange: 0.1...0.9)
        // Verify: same streams, same duration, removed keys gone.
        let written = try await self.probe(output)
        guard written.streams.count == kept.count,
              probe.duration <= 0 || abs(written.duration - probe.duration) <= max(0.5, probe.duration * 0.02) else {
            throw GeneralToolFailure("The output could not be verified. No output was saved.")
        }
        let remaining = try await read(output).fields
        let survivor: MetadataField?
        if let changes {
            survivor = remaining.first { changes.removed.contains($0.id) }
        } else {
            survivor = remaining.first { !$0.id.hasSuffix(":language") }
        }
        if let survivor { throw GeneralToolFailure(MetadataText.notSaved(survivor.label)) }
    }
}

// MARK: - PDF

enum PDFMetadataIO {
    static let order: [(PDFDocumentAttribute, String)] = [
        (.titleAttribute, "Title"), (.authorAttribute, "Author"), (.subjectAttribute, "Subject"), (.keywordsAttribute, "Keywords"),
        (.creatorAttribute, "Created With"), (.producerAttribute, "Producer"), (.creationDateAttribute, "Created"),
        (.modificationDateAttribute, "Modified"),
    ]
    static let editable: Set<PDFDocumentAttribute> = [.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute, .creatorAttribute]
    static let sensitive: Set<PDFDocumentAttribute> = [.authorAttribute, .creatorAttribute, .producerAttribute]

    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), !document.isLocked else { throw DocumentError.unreadablePDF }
        return document
    }

    static func read(_ url: URL) throws -> MetadataReport {
        let document = try open(url)
        let attributes = document.documentAttributes ?? [:]
        var fields: [MetadataField] = []
        for (key, label) in order {
            guard let value = attributes[key] else { continue }
            let text: String
            if let date = value as? Date {
                text = date.formatted(date: .abbreviated, time: .shortened)
            } else if let list = value as? [Any] {
                text = list.map { "\($0)" }.joined(separator: ", ")
            } else {
                text = "\(value)"
            }
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            fields.append(MetadataField(id: "pdf:\(key.rawValue)", section: "Document", label: label, value: text,
                                        editable: editable.contains(key), removable: true, sensitive: sensitive.contains(key)))
        }
        return MetadataReport(kind: .pdf, sections: fields.isEmpty ? [] : [MetadataSection(title: "Document", symbol: "doc.richtext", fields: fields)])
    }

    static func write(_ url: URL, to output: URL, changes: MetadataChanges?) throws {
        let document = try open(url)
        let pageCount = document.pageCount
        // Plain string keys ("Title"), as PDFKit returns them.
        var attributes: [String: Any] = [:]
        if let changes {
            for (key, value) in document.documentAttributes ?? [:] {
                if let key = key.base as? String { attributes[key] = value }
            }
            for id in changes.removed { attributes[String(id.dropFirst(4))] = nil }
            for (id, value) in changes.edits where !changes.removed.contains(id) {
                let key = String(id.dropFirst(4))
                attributes[key] = key == PDFDocumentAttribute.keywordsAttribute.rawValue
                    ? value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } as Any
                    : value as Any
            }
        }
        document.documentAttributes = attributes
        guard document.write(to: output) else { throw GeneralToolFailure("PDFKit could not write the cleaned PDF.") }
        guard let check = PDFDocument(url: output), check.pageCount == pageCount else {
            throw GeneralToolFailure("The PDF could not be verified.")
        }
        let remaining = check.documentAttributes ?? [:]
        let removedKeys = changes.map { Array($0.removed) } ?? ["pdf:Title", "pdf:Author", "pdf:Subject", "pdf:Keywords", "pdf:Creator"]
        for id in removedKeys where remaining[PDFDocumentAttribute(rawValue: String(id.dropFirst(4)))] != nil {
            // PDFKit always stamps Producer and dates; everything else must be gone.
            let key = PDFDocumentAttribute(rawValue: String(id.dropFirst(4)))
            if key == .producerAttribute || key == .creationDateAttribute || key == .modificationDateAttribute { continue }
            throw GeneralToolFailure(MetadataText.notSaved(key.rawValue))
        }
    }
}
