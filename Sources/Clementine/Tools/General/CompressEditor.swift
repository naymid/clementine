import AppKit
import SwiftUI

/// Compress: one preset for every file family, an optional image/video size cap,
/// and an optional target file size.
struct CompressEditorView: View {
    @ObservedObject var session: ToolSession

    enum TargetUnit: String, CaseIterable, Hashable {
        case kb = "KB", mb = "MB"
        var multiplier: Double { self == .kb ? 1_000 : 1_000_000 }
    }

    @State private var strength: CompressionStrength
    @State private var imageSize: ImageSizeLimit
    @State private var videoHeight: Int
    @State private var useTarget: Bool
    @State private var targetText: String
    @State private var targetUnit: TargetUnit
    @State private var preview: CGImage?
    private let sizes: [Int64]

    private static let stillImages: Set<FileFormat> = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp]

    init(session: ToolSession, startWithTarget: Bool = false) {
        self.session = session
        let formats = session.formats
        let settings = AppSettings.shared
        _strength = State(initialValue: settings.compression(for: formats.first ?? .jpg).strength)
        let firstImage = formats.first { Self.stillImages.contains($0) }
        _imageSize = State(initialValue: firstImage.map { settings.compression(for: $0).sizeLimit } ?? .original)
        let firstVideo = formats.first { $0.family == .video && $0 != .gif }
        _videoHeight = State(initialValue: firstVideo.map { settings.options(for: $0).maxVideoHeight } ?? 0)
        let sizes = session.urls.map { GeneralSizeText.bytes(of: $0) }
        self.sizes = sizes
        // Suggest half the largest file.
        let half = Double(sizes.max() ?? 0) / 2
        if half >= 1_000_000 {
            _targetUnit = State(initialValue: .mb)
            _targetText = State(initialValue: String(format: "%.1f", half / 1_000_000))
        } else {
            _targetUnit = State(initialValue: .kb)
            _targetText = State(initialValue: "\(max(1, Int(half / 1_000)))")
        }
        _useTarget = State(initialValue: startWithTarget)
    }

    private var formats: [FileFormat] { session.formats }
    private var hasStillImages: Bool { formats.contains { Self.stillImages.contains($0) } }
    private var hasVideo: Bool { formats.contains { $0.family == .video && $0 != .gif } }
    private var videoOnly: Bool { !formats.isEmpty && formats.allSatisfy { $0.family == .video && $0 != .gif } }
    private var totalSize: Int64 { sizes.reduce(0, +) }
    private var largestSize: Int64 { sizes.max() ?? 0 }

    private var targetBytes: Int64? {
        let normalized = targetText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value > 0 else { return nil }
        return Int64((value * targetUnit.multiplier).rounded())
    }

    private var validationMessage: String? {
        guard useTarget else { return nil }
        guard let bytes = targetBytes, bytes >= CompressionRequest.minimumTarget, bytes <= CompressionRequest.maximumTarget else {
            return CompressionText.targetRange
        }
        if largestSize > 0, bytes > largestSize { return CompressionText.targetAboveOriginal }
        return nil
    }

    var body: some View {
        ToolScaffold(session: session) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    ToolSection("Compression preset") {
                        ToolSegmented(selection: $strength, options: [(.balanced, "Balanced"), (.strong, "Strong")])
                            .accessibilityLabel("Compression preset")
                        Text(videoOnly ? strength.videoDescription() : strength.imageDescription())
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if hasStillImages || hasVideo {
                        ToolSection {
                            if hasStillImages {
                                ToolSettingRow("Image size") {
                                    Picker("Image size", selection: $imageSize) {
                                        ForEach(ImageSizeLimit.allCases) { Text($0.title).tag($0) }
                                    }
                                    .labelsHidden()
                                    .fixedSize()
                                }
                            }
                            if hasStillImages && hasVideo { Divider().opacity(0.5) }
                            if hasVideo {
                                ToolSettingRow("Maximum video height") {
                                    Picker("Maximum video height", selection: $videoHeight) {
                                        Text("Original").tag(0)
                                        ForEach([2160, 1440, 1080, 720, 480], id: \.self) { Text("\($0)p").tag($0) }
                                    }
                                    .labelsHidden()
                                    .fixedSize()
                                }
                            }
                        }
                    }
                    ToolSection {
                        GeneralSwitchRow(title: "Compress to target file size", isOn: $useTarget.animation(.easeInOut(duration: 0.15)))
                            .accessibilityIdentifier("compressionTargetToggle")
                        if useTarget {
                            ToolSettingRow("Target file size") {
                                HStack(spacing: 8) {
                                    TextField("Size", text: $targetText)
                                        .textFieldStyle(.roundedBorder)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 80)
                                        .accessibilityLabel("Target file size")
                                    ToolSegmented(selection: $targetUnit, options: TargetUnit.allCases.map { ($0, $0.rawValue) })
                                }
                                .onChange(of: targetUnit) { old, new in
                                    // Keep the same size when switching units: 1500 KB ⇄ 1.5 MB.
                                    let normalized = targetText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                                    guard let value = Double(normalized) else { return }
                                    let converted = value * old.multiplier / new.multiplier
                                    targetText = converted == converted.rounded() ? String(Int(converted))
                                                                                  : String(format: "%.2f", converted)
                                }
                            }
                            if let validationMessage {
                                GeneralWarningText(text: validationMessage)
                            } else {
                                Text(session.urls.count > 1 ? "Each file is compressed to this size or smaller."
                                                            : "Quality and size are reduced only as much as needed.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(16)
            }
        } footer: {
            ToolFooter(session: session, primaryTitle: "Compress", primaryEnabled: validationMessage == nil, action: run)
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            ZStack {
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: session.primaryURL.path))
                        .resizable()
                        .frame(width: 40, height: 40)
                }
                if session.urls.count > 1 {
                    Text("\(session.urls.count)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Brand.buttonOrange))
                        .offset(x: 18, y: -18)
                }
            }
            .frame(width: 40, height: 40)
            .task { await loadPreview() }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.urls.count == 1 ? session.primaryURL.lastPathComponent : "\(session.urls.count) files")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(kindDescription)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Original size")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(GeneralSizeText.describe(totalSize))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .accessibilityIdentifier("compressionOriginalSize")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    /// A real thumbnail of the first file: image, first PDF page, or a video frame.
    private func loadPreview() async {
        guard preview == nil, let format = formats.first else { return }
        let url = session.primaryURL
        switch format.family {
        case .image: preview = await GeneralThumbnails.image(url, maxPixel: 120)
        case .document: preview = await GeneralThumbnails.pdfCover(url, maxDimension: 120).0
        case .video:
            if format == .gif { preview = await GeneralThumbnails.image(url, maxPixel: 120) }
            else { preview = await ThumbnailLoader.frame(for: url, at: 0.5, maxSize: CGSize(width: 160, height: 160)) }
        default: break
        }
    }

    private var kindDescription: String {
        let labels = Array(Set(formats.map(\.label))).sorted()
        if labels.count == 1 {
            switch formats.first?.family {
            case .image: return "\(labels[0]) image"
            case .video: return formats.first == .gif ? "Animated GIF" : "\(labels[0]) video"
            case .audio: return "\(labels[0]) audio"
            case .document: return "PDF document"
            default: return labels[0]
            }
        }
        return labels.joined(separator: ", ")
    }

    private func run() {
        guard validationMessage == nil else { return }
        let request = CompressionRequest(strength: strength, imageSize: imageSize, maxVideoHeight: videoHeight,
                                         targetBytes: useTarget ? targetBytes : nil)
        let originalTotal = totalSize
        let count = session.urls.count
        session.runPerItem(successTitle: { outputs in
            let after = outputs.reduce(Int64(0)) { $0 + GeneralSizeText.bytes(of: $1) }
            guard outputs.count == count, originalTotal > after, originalTotal > 0 else { return JobCenter.defaultSuccessTitle(outputs) }
            let percent = Int((Double(originalTotal - after) / Double(originalTotal) * 100).rounded())
            return "\(percent)% smaller · saved \(FileNaming.formattedSize(originalTotal - after))"
        }) { url, context in
            [try await FileCompressor.compress(url, request: request, context: context)]
        }
    }
}
