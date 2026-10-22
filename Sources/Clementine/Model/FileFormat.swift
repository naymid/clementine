import Foundation
import UniformTypeIdentifiers

/// The broad kind of file a format belongs to. Drives which tools and engines apply.
enum FormatFamily: String, CaseIterable, Codable {
    case image, document, audio, video, archive, subtitle

    var title: String {
        switch self {
        case .image: return "Images"
        case .document: return "Documents"
        case .audio: return "Audio"
        case .video: return "Video"
        case .archive: return "Archives"
        case .subtitle: return "Subtitles"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo.on.rectangle.angled"
        case .document: return "doc.text"
        case .audio: return "waveform"
        case .video: return "film"
        case .archive: return "archivebox"
        case .subtitle: return "captions.bubble"
        }
    }
}

/// Every format Clementine reads or writes. Order matches the original app's
/// compatibility tables, which is also the clockwise order of wheel petals.
enum FileFormat: String, CaseIterable, Codable, Identifiable, Hashable {
    case jpg, png, webp, heic, tiff, svg, avif, bmp
    case pdf, docx, txt
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma
    case mp4, mov, mkv, webm, avi, wmv, gif
    case zip, tar, gzip, rar
    case srt, vtt

    var id: String { rawValue }

    /// Uppercase label shown on petals and in settings.
    var label: String { rawValue.uppercased() }

    var family: FormatFamily {
        switch self {
        case .jpg, .png, .webp, .heic, .tiff, .svg, .avif, .bmp: return .image
        case .pdf, .docx, .txt: return .document
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma: return .audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .gif: return .video
        case .zip, .tar, .gzip, .rar: return .archive
        case .srt, .vtt: return .subtitle
        }
    }

    /// Extension used for files Clementine writes.
    var outputExtension: String {
        switch self {
        case .gzip: return "tar.gz"
        default: return rawValue
        }
    }

    /// Formats listed in Settings → Formats (every output format, original order).
    static let settingsOrder: [FileFormat] = [
        .jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf, .docx, .txt,
        .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma,
        .mp4, .mov, .mkv, .webm, .avi, .wmv, .gif,
        .zip, .tar, .gzip, .rar, .srt, .vtt,
    ]

    /// Detects the format of a file on disk from its name.
    static func detect(_ url: URL) -> FileFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") || name.hasSuffix(".gz") { return .gzip }
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe", "jfif": return .jpg
        case "png": return .png
        case "webp": return .webp
        case "heic", "heif", "hif": return .heic
        case "tif", "tiff": return .tiff
        case "svg": return .svg
        case "avif": return .avif
        case "bmp", "dib": return .bmp
        case "pdf": return .pdf
        case "docx": return .docx
        case "txt", "text": return .txt
        case "mp3": return .mp3
        case "m4a", "aac": return .m4a
        case "wav", "wave": return .wav
        case "flac": return .flac
        case "ogg", "oga": return .ogg
        case "opus": return .opus
        case "aif", "aiff", "aifc": return .aiff
        case "wma": return .wma
        case "mp4", "m4v": return .mp4
        case "mov", "qt": return .mov
        case "mkv": return .mkv
        case "webm": return .webm
        case "avi": return .avi
        case "wmv", "asf": return .wmv
        case "gif": return .gif
        case "zip": return .zip
        case "tar": return .tar
        case "rar": return .rar
        case "srt": return .srt
        case "vtt": return .vtt
        default: return nil
        }
    }
}

/// The conversion compatibility matrix, transcribed from the original app's
/// Settings → Compatibility tables. Targets are listed in petal order.
enum FormatCompatibility {
    struct Table: Identifiable {
        let family: FormatFamily
        let sources: [FileFormat]
        let targets: [FileFormat]
        var id: FormatFamily { family }
    }

    static let tables: [Table] = [
        Table(family: .image,
              sources: [.jpg, .png, .webp, .heic, .tiff, .svg, .avif, .bmp],
              targets: [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf, .docx]),
        Table(family: .document,
              sources: [.pdf, .txt],
              targets: [.pdf, .docx, .txt, .jpg, .png, .srt, .vtt]),
        Table(family: .audio,
              sources: [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma],
              targets: [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]),
        Table(family: .video,
              sources: [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif],
              targets: [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mp3]),
        Table(family: .archive,
              sources: [.zip, .tar, .gzip, .rar],
              targets: [.zip, .tar, .gzip, .rar]),
        Table(family: .subtitle,
              sources: [.srt, .vtt, .txt],
              targets: [.srt, .vtt, .txt]),
    ]

    private static let targetsBySource: [FileFormat: [FileFormat]] = {
        var map: [FileFormat: [FileFormat]] = [:]
        let all = Set(FileFormat.allCases)
        let image: Set<FileFormat> = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf]
        for source in [FileFormat.jpg, .png] { map[source] = ordered(image.union([.docx]).subtracting([source])) }
        for source in [FileFormat.webp, .heic, .tiff, .avif, .bmp] { map[source] = ordered(image.subtracting([source])) }
        map[.svg] = ordered(image)
        map[.pdf] = [.docx, .txt, .jpg, .png]
        map[.txt] = [.pdf, .jpg, .png, .srt, .vtt]
        let audio: [FileFormat] = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]
        for source in audio { map[source] = audio.filter { $0 != source } }
        // WEBM is never offered as a video output in the original.
        let videoTargets: [FileFormat] = [.mp4, .mov, .mkv, .avi, .wmv, .gif, .mp3]
        for source in [FileFormat.mp4, .mov, .mkv, .webm, .avi, .wmv] { map[source] = videoTargets.filter { $0 != source } }
        map[.gif] = [.mp4, .mov, .mkv, .avi, .wmv]
        let archives: [FileFormat] = [.zip, .tar, .gzip, .rar]
        for source in archives { map[source] = archives.filter { $0 != source } }
        map[.srt] = [.vtt, .txt]
        map[.vtt] = [.srt, .txt]
        _ = all
        return map
    }()

    private static func ordered(_ set: Set<FileFormat>) -> [FileFormat] {
        FileFormat.allCases.filter { set.contains($0) && $0 != .svg }
    }

    static func targets(for source: FileFormat) -> [FileFormat] {
        targetsBySource[source] ?? []
    }

    static func isSupported(_ source: FileFormat, _ target: FileFormat) -> Bool {
        targets(for: source).contains(target)
    }

    /// Targets every source in a drop can be converted to, in petal order.
    static func sharedTargets(for sources: [FileFormat]) -> [FileFormat] {
        guard let first = sources.first else { return [] }
        var result = targets(for: first)
        for source in sources.dropFirst() {
            let allowed = Set(targets(for: source))
            result = result.filter { allowed.contains($0) }
        }
        return result
    }

    static var totalConversions: Int {
        FileFormat.allCases.reduce(0) { $0 + targets(for: $1).count }
    }
}
