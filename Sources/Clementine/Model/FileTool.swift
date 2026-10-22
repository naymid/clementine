import Foundation

/// Tools offered on the tools wheel. Case order is the clockwise petal order.
enum FileTool: String, CaseIterable, Codable, Identifiable {
    case compress
    case removeMetadata
    case editImage
    case annotateImage
    case frameImage
    case cropImage
    case normalizeAudio
    case muteVideo
    case trimVideo
    case splitPDF
    case organizePDF
    case extractArchive
    case createPDF
    case mergePDF
    case cropVideo
    case changeVideoSpeed
    case joinVideos
    case videoSnapshots
    case splitVideo
    case audioToVideo
    case trimAudio
    case audioChannels
    case createCollage
    case readQRCode
    case redactImage
    case redactVideo
    case redactAudio

    var id: String { rawValue }

    /// Short uppercase label drawn on the petal.
    var petalLabel: String {
        switch self {
        case .compress: return "Compress"
        case .removeMetadata: return "Metadata"
        case .editImage: return "Adjust"
        case .annotateImage: return "Annotate"
        case .frameImage: return "Background"
        case .cropImage, .cropVideo: return "Crop"
        case .normalizeAudio: return "Normalize"
        case .muteVideo: return "Mute"
        case .trimVideo, .trimAudio: return "Trim"
        case .splitPDF, .splitVideo: return "Split"
        case .organizePDF: return "Organize"
        case .extractArchive: return "Extract"
        case .createPDF: return "Make PDF"
        case .mergePDF: return "Merge"
        case .changeVideoSpeed: return "Speed"
        case .joinVideos: return "Join"
        case .videoSnapshots: return "Snapshot"
        case .audioToVideo: return "Visualize"
        case .audioChannels: return "Channels"
        case .createCollage: return "Collage"
        case .readQRCode: return "QR Code"
        case .redactImage, .redactVideo: return "Redact"
        case .redactAudio: return "Bleep"
        }
    }

    /// Window title for the tool's editor or progress HUD.
    var title: String {
        switch self {
        case .compress: return "Compress"
        case .removeMetadata: return "Metadata"
        case .editImage: return "Adjust Photo"
        case .annotateImage: return "Annotate Photo"
        case .frameImage: return "Change Background"
        case .cropImage: return "Crop Image"
        case .normalizeAudio: return "Normalize Volume"
        case .muteVideo: return "Mute Video"
        case .trimVideo: return "Trim Video"
        case .splitPDF: return "Split PDF"
        case .organizePDF: return "Organize PDF"
        case .extractArchive: return "Extract Archive"
        case .createPDF: return "Create PDF"
        case .mergePDF: return "Merge PDFs"
        case .cropVideo: return "Crop Video"
        case .changeVideoSpeed: return "Change Video Speed"
        case .joinVideos: return "Join Videos"
        case .videoSnapshots: return "Video Snapshots"
        case .splitVideo: return "Split Video"
        case .audioToVideo: return "Audio Visualizer"
        case .trimAudio: return "Trim Audio"
        case .audioChannels: return "Convert Audio Channels"
        case .createCollage: return "Create Collage"
        case .readQRCode: return "Read QR Codes"
        case .redactImage: return "Redact Photo"
        case .redactVideo: return "Redact Video"
        case .redactAudio: return "Bleep Audio"
        }
    }

    /// Progress line shown while the tool runs.
    var workingTitle: String {
        switch self {
        case .compress: return "Compressing"
        case .removeMetadata: return "Removing metadata"
        case .editImage: return "Editing photo"
        case .annotateImage: return "Annotating photo"
        case .frameImage: return "Adding background"
        case .cropImage, .cropVideo: return "Cropping"
        case .normalizeAudio: return "Normalizing volume"
        case .muteVideo: return "Muting video"
        case .trimVideo, .trimAudio: return "Trimming"
        case .splitPDF: return "Splitting PDF"
        case .organizePDF: return "Organizing PDF"
        case .extractArchive: return "Extracting archive"
        case .createPDF: return "Creating PDF"
        case .mergePDF: return "Merging PDFs"
        case .changeVideoSpeed: return "Changing speed"
        case .joinVideos: return "Joining videos"
        case .videoSnapshots: return "Saving snapshots"
        case .splitVideo: return "Splitting video"
        case .audioToVideo: return "Creating visualization"
        case .audioChannels: return "Converting channels"
        case .createCollage: return "Creating collage"
        case .readQRCode: return "Reading QR codes"
        case .redactImage: return "Redacting photo"
        case .redactVideo: return "Redacting video"
        case .redactAudio: return "Bleeping audio"
        }
    }

    var symbol: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .removeMetadata: return "tag"
        case .editImage: return "slider.horizontal.3"
        case .annotateImage: return "pencil.tip.crop.circle"
        case .frameImage: return "photo.artframe"
        case .cropImage, .cropVideo: return "crop"
        case .normalizeAudio: return "speaker.wave.2"
        case .muteVideo: return "speaker.slash"
        case .trimVideo, .trimAudio: return "scissors"
        case .splitPDF: return "rectangle.split.2x1"
        case .organizePDF: return "square.grid.2x2"
        case .extractArchive: return "archivebox"
        case .createPDF: return "doc.richtext"
        case .mergePDF: return "doc.on.doc"
        case .changeVideoSpeed: return "gauge.with.dots.needle.67percent"
        case .joinVideos: return "rectangle.stack.badge.plus"
        case .videoSnapshots: return "camera"
        case .splitVideo: return "film"
        case .audioToVideo: return "waveform.badge.plus"
        case .audioChannels: return "hifispeaker.2"
        case .createCollage: return "square.grid.3x2"
        case .readQRCode: return "qrcode.viewfinder"
        case .redactImage, .redactVideo: return "eye.slash"
        case .redactAudio: return "waveform.badge.minus"
        }
    }

    /// Tools that act immediately on drop instead of opening an editor.
    var runsImmediately: Bool {
        switch self {
        case .muteVideo, .extractArchive, .readQRCode: return true
        default: return false
        }
    }

    /// Whether the tool works on this selection of files.
    func applies(to formats: [FileFormat]) -> Bool {
        guard !formats.isEmpty else { return false }
        let families = Set(formats.map(\.family))
        let allImages = formats.allSatisfy { $0.family == .image }
        let allVideo = formats.allSatisfy { $0.family == .video && $0 != .gif }
        let allAudio = formats.allSatisfy { $0.family == .audio }
        let allPDF = formats.allSatisfy { $0 == .pdf }
        let single = formats.count == 1
        switch self {
        case .compress:
            return formats.allSatisfy { [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf, .gif].contains($0) || $0.family == .video || $0.family == .audio }
        case .removeMetadata:
            return formats.allSatisfy { [.jpg, .png, .webp, .heic, .tiff, .avif, .pdf].contains($0) || $0.family == .video || $0.family == .audio } && families.count == 1
        case .editImage, .frameImage, .cropImage:
            return allImages && !formats.contains(.svg)
        case .annotateImage, .redactImage:
            return allImages && single && formats[0] != .svg
        case .readQRCode:
            return allImages || allPDF
        case .createPDF:
            return allImages && formats.count >= 1
        case .createCollage:
            return allImages && formats.count >= 2 && !formats.contains(.svg)
        case .normalizeAudio, .trimAudio, .audioChannels, .audioToVideo:
            return allAudio && (self != .trimAudio || single) && (self != .audioToVideo || single)
        case .redactAudio:
            return allAudio && single
        case .muteVideo:
            return allVideo
        case .trimVideo, .cropVideo, .changeVideoSpeed, .videoSnapshots, .splitVideo, .redactVideo:
            return allVideo && single
        case .joinVideos:
            return allVideo && formats.count >= 2
        case .splitPDF, .organizePDF:
            return allPDF && single
        case .mergePDF:
            return allPDF && formats.count >= 2
        case .extractArchive:
            return formats.allSatisfy { $0.family == .archive }
        }
    }

    static func tools(for formats: [FileFormat]) -> [FileTool] {
        allCases.filter { $0.applies(to: formats) }
    }
}
