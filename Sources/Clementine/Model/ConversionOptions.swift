import Foundation

enum ConversionQuality: String, Codable, CaseIterable, Identifiable {
    case smaller, balanced, higher
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smaller: return "Smaller File"
        case .balanced: return "Balanced"
        case .higher: return "Higher Quality"
        }
    }
}

enum CompressionSpeed: String, Codable, CaseIterable, Identifiable {
    case faster, balanced, smallest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .faster: return "Faster"
        case .balanced: return "Balanced"
        case .smallest: return "Smallest File"
        }
    }
}

enum CompressionStrength: String, Codable, CaseIterable, Identifiable {
    case balanced, strong
    var id: String { rawValue }
    var title: String { self == .balanced ? "Balanced" : "Strong" }
}

enum ImageSizeLimit: Int, Codable, CaseIterable, Identifiable {
    case original = 0, px2560 = 2560, px1920 = 1920, px1280 = 1280
    var id: Int { rawValue }
    var title: String { self == .original ? "Keep original dimensions" : "\(rawValue) px longest edge" }
    var longestEdge: Int? { self == .original ? nil : rawValue }
}

/// Conversion defaults for one output format (Settings → Formats → Conversion Settings).
struct FormatOptions: Codable, Equatable {
    var quality: ConversionQuality = .balanced
    var preserveMetadata = true
    var audioBitrate = 256
    var compressionSpeed: CompressionSpeed = .balanced
    var maxVideoHeight = 0
    var gifFrameRate = 15
    var gifMaxWidth = 960

    static func defaults(for format: FileFormat) -> FormatOptions {
        var options = FormatOptions()
        if format == .mov { options.quality = .higher }
        return options
    }
}

/// Compression defaults for one format (Settings → Formats → Image/Compression Settings).
struct CompressionOptions: Codable, Equatable {
    var strength: CompressionStrength = .balanced
    var sizeLimit: ImageSizeLimit = .original
}

/// Which settings rows a format shows in Settings → Formats.
struct FormatSettingsLayout {
    var quality = false
    var preserveMetadata = false
    var audioBitrate = false
    var compressionSpeed = false
    var videoHeight = false
    var gif = false
    var imageCompression = false
    var videoCompression = false

    var hasConversionSettings: Bool { quality || preserveMetadata || audioBitrate || compressionSpeed || videoHeight || gif }

    static func layout(for format: FileFormat) -> FormatSettingsLayout {
        var layout = FormatSettingsLayout()
        switch format {
        case .jpg, .webp, .heic, .avif:
            layout.quality = true
            layout.preserveMetadata = true
        case .png, .tiff:
            layout.preserveMetadata = true
        case .mp3, .m4a, .ogg, .opus, .wma:
            layout.audioBitrate = true
        case .flac, .zip, .gzip:
            layout.compressionSpeed = true
        case .mp4, .mov, .mkv, .webm, .avi, .wmv:
            layout.quality = true
            layout.videoHeight = true
            layout.videoCompression = true
        case .gif:
            layout.gif = true
            layout.videoCompression = true
        default:
            break
        }
        if format == .jpg || format == .png { layout.imageCompression = true }
        return layout
    }
}

extension CompressionStrength {
    func imageDescription() -> String {
        self == .balanced ? "Smaller files with less quality loss." : "Smaller files with more quality loss."
    }

    func videoDescription() -> String {
        self == .balanced ? "Better visual quality with moderate file-size savings." : "Much smaller files with more visible quality loss."
    }
}
