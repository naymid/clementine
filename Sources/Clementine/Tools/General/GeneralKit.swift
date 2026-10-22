import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// Shared pieces for the general tools (compression, metadata, PDF tools, QR codes, archives).

/// A user-facing failure with a ready-made message.
struct GeneralToolFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Sizes

enum GeneralSizeText {
    /// The current size on disk. Unlike URL resource values this is never cached,
    /// which matters when one scratch file is rewritten many times.
    static func bytes(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if isDirectory.boolValue { return FileNaming.size(of: url) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return size ?? 0
    }

    /// "1.2 MB", or "Size unavailable" when the size is unknown.
    static func describe(_ bytes: Int64) -> String {
        bytes > 0 ? FileNaming.formattedSize(bytes) : "Size unavailable"
    }

    /// Parses "200KB", "1.5 MB", "300 kb" or a plain byte count.
    static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
        let units: [(String, Double)] = [("tb", 1e12), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3), ("b", 1)]
        for (suffix, multiplier) in units where trimmed.hasSuffix(suffix) {
            let number = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number), value > 0 else { return nil }
            return Int64((value * multiplier).rounded())
        }
        guard let value = Double(trimmed), value > 0 else { return nil }
        return Int64(value.rounded())
    }
}

// MARK: - Thumbnails

enum GeneralThumbnails {
    /// Renders each page of a PDF so its longest edge is about `maxDimension` pixels.
    /// Page rotation is applied. Runs off the main thread.
    static func pdfPages(_ url: URL, maxDimension: CGFloat) async -> [CGImage?] {
        await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url), !document.isLocked else { return [] }
            return (0..<document.pageCount).map { index -> CGImage? in
                guard let page = document.page(at: index) else { return nil }
                let bounds = page.bounds(for: .cropBox)
                let longest = max(bounds.width, bounds.height, 1)
                return DocumentConverter.render(page, scale: max(0.05, maxDimension / longest))
            }
        }.value
    }

    /// The first page of a PDF, plus its page count.
    static func pdfCover(_ url: URL, maxDimension: CGFloat) async -> (CGImage?, Int) {
        await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url), !document.isLocked, let page = document.page(at: 0) else { return (nil, 0) }
            let bounds = page.bounds(for: .cropBox)
            let image = DocumentConverter.render(page, scale: max(0.05, maxDimension / max(bounds.width, bounds.height, 1)))
            return (image, document.pageCount)
        }.value
    }

    /// An upright thumbnail of an image file.
    static func image(_ url: URL, maxPixel: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            if url.pathExtension.lowercased() == "svg" {
                return try? ImageIOHelpers.load(url, maxPixel: maxPixel).image
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}

// MARK: - Drag to reorder

/// Moves the dragged item onto the hovered item's slot while a drag passes over it.
struct GeneralReorderDelegate<ID: Hashable>: DropDelegate {
    let target: ID
    @Binding var dragging: ID?
    let move: (_ dragged: ID, _ target: ID) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeInOut(duration: 0.18)) { move(dragging, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Ends a reorder drag that is dropped between items.
struct GeneralReorderEndDelegate<ID: Hashable>: DropDelegate {
    @Binding var dragging: ID?
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

enum GeneralOrdering {
    /// Moves the element with `dragged` id to the position of `target`.
    static func move<Item, ID: Hashable>(_ items: inout [Item], id: KeyPath<Item, ID>, dragged: ID, target: ID) {
        guard let from = items.firstIndex(where: { $0[keyPath: id] == dragged }),
              let to = items.firstIndex(where: { $0[keyPath: id] == target }), from != to else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
    }

    /// Finder-style name order ("Page 2" before "Page 10").
    static func finderOrder(_ a: URL, _ b: URL) -> Bool {
        a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
    }
}

// MARK: - Small views

/// A page or image thumbnail on a white card, with a shadow, sized to fit its frame.
struct GeneralThumbnailCard: View {
    var image: CGImage?
    var rotation: Int = 0
    var aspect: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let size = fittedSize(in: proxy.size)
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rotation % 180 == 0 ? size.width : size.height,
                               height: rotation % 180 == 0 ? size.height : size.width)
                        .rotationEffect(.degrees(Double(rotation)))
                        .frame(width: size.width, height: size.height)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                } else {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: size.width, height: size.height)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func fittedSize(in box: CGSize) -> CGSize {
        var ratio: CGFloat = aspect ?? 0.77
        if let image { ratio = CGFloat(image.width) / CGFloat(max(image.height, 1)) }
        if rotation % 180 != 0 { ratio = 1 / ratio }
        let width = min(box.width, box.height * ratio)
        return CGSize(width: max(1, width), height: max(1, width / ratio))
    }
}

/// A small round icon button used on thumbnails and rows.
struct GeneralIconButton: View {
    var symbol: String
    var help: String
    var tint: Color = .primary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The orange check toggle row, e.g. "Make all pages the same width" plus its note.
struct GeneralToggleRow: View {
    var title: String
    var note: String?
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeneralSwitchRow(title: title, isOn: $isOn)
            if let note, isOn {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Title ........ (switch)", like the settings rows.
struct GeneralSwitchRow: View {
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }
}

/// An inline validation message.
struct GeneralWarningText: View {
    var text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11.5))
            .foregroundStyle(Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Test option helpers

enum GeneralTestOptions {
    static func bool(_ options: [String: String], _ key: String) -> Bool {
        guard let value = options[key]?.lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(value)
    }

    static func int(_ options: [String: String], _ key: String) -> Int? {
        options[key].flatMap { Int($0) }
    }

    static func list(_ options: [String: String], _ key: String) -> [String] {
        (options[key] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
