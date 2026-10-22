import AppKit
import PDFKit
import CoreText

enum DocumentError: LocalizedError {
    case unreadablePDF
    case noText
    case textTooLong
    case notUTF8
    case layoutFailed

    var errorDescription: String? {
        switch self {
        case .unreadablePDF: return "The PDF cannot be read or is password-protected."
        case .noText: return "This PDF has no selectable text. Scanned pages need OCR before text can be exported."
        case .textTooLong: return "The text is too long to fit in a single image."
        case .notUTF8: return "The text file is not valid UTF-8."
        case .layoutFailed: return "The text could not be laid out on a PDF page."
        }
    }
}

enum DocumentConverter {
    // MARK: PDF sources

    static func convertPDF(_ source: URL, to target: FileFormat, context: JobContext) async throws -> [URL] {
        guard let document = PDFDocument(url: source), !document.isLocked else { throw DocumentError.unreadablePDF }
        switch target {
        case .txt:
            let text = pageTexts(document).joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DocumentError.noText }
            let output = FileNaming.output(beside: source, extension: "txt")
            try text.write(to: output, atomically: true, encoding: .utf8)
            return [output]
        case .docx:
            let texts = pageTexts(document)
            guard texts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw DocumentError.noText }
            var blocks: [DocxWriter.Block] = []
            for (index, text) in texts.enumerated() {
                if index > 0 { blocks.append(.pageBreak) }
                let paragraphs = text.components(separatedBy: "\n\n")
                for paragraph in paragraphs where !paragraph.isEmpty {
                    blocks.append(.paragraph(paragraph))
                }
            }
            let output = FileNaming.output(beside: source, extension: "docx")
            try DocxWriter.write(blocks: blocks, to: output)
            return [output]
        case .jpg, .png:
            return try renderPages(document, source: source, format: target, context: context)
        default:
            throw ConversionError.unsupported(.pdf, target)
        }
    }

    static func pageTexts(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    /// Renders every page at 2x. Multi-page PDFs go into a folder beside the original.
    static func renderPages(_ document: PDFDocument, source: URL, format: FileFormat, context: JobContext) throws -> [URL] {
        let count = document.pageCount
        guard count > 0 else { throw DocumentError.unreadablePDF }
        let directory: URL
        if count == 1 {
            directory = source.deletingLastPathComponent()
        } else {
            directory = FileNaming.folder(beside: source, suffix: " pages")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var outputs: [URL] = []
        for index in 0..<count {
            try context.checkCancelled()
            guard let page = document.page(at: index), let image = render(page, scale: 2) else {
                throw ImageError.writeFailed("Could not render PDF page \(index + 1).")
            }
            let base = count == 1 ? FileNaming.baseName(of: source) : "\(FileNaming.baseName(of: source)) \(index + 1)"
            let url = FileNaming.uniqueURL(in: directory, base: base, extension: format.outputExtension)
            try ImageIOHelpers.write(image, to: url, format: format, quality: format == .jpg ? 0.9 : nil)
            outputs.append(url)
            context.progress(Double(index + 1) / Double(count))
        }
        return count == 1 ? outputs : [directory]
    }

    static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    // MARK: Text sources

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        throw DocumentError.notUTF8
    }

    static func convertText(_ source: URL, to target: FileFormat, context: JobContext) async throws -> [URL] {
        switch target {
        case .srt, .vtt:
            return try SubtitleConverter.convert(source, to: target)
        case .pdf:
            let text = try readText(source)
            let output = FileNaming.output(beside: source, extension: "pdf")
            try writeTextPDF(text, to: output)
            return [output]
        case .jpg, .png:
            let text = try readText(source)
            let image = try renderTextImage(text)
            let output = FileNaming.output(beside: source, extension: target.outputExtension)
            try ImageIOHelpers.write(image, to: output, format: target, quality: target == .jpg ? 0.92 : nil)
            return [output]
        default:
            throw ConversionError.unsupported(.txt, target)
        }
    }

    static func textAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.25
        return [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
    }

    /// Lays text onto US Letter pages with one-inch margins.
    static func writeTextPDF(_ text: String, to output: URL) throws {
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: textAttributes(fontSize: 12))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else { throw DocumentError.layoutFailed }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frameRect = mediaBox.insetBy(dx: 72, dy: 72)
        var location = 0
        let length = attributed.length
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            guard visible.length > 0 else { context.closePDF(); throw DocumentError.layoutFailed }
            location += visible.length
        } while location < length
        context.closePDF()
    }

    /// Renders text into one tall image, 1200 px wide.
    static func renderTextImage(_ text: String) throws -> CGImage {
        let width: CGFloat = 1200
        let padding: CGFloat = 72
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: textAttributes(fontSize: 30))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraint = CGSize(width: width - padding * 2, height: .greatestFiniteMagnitude)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        let height = ceil(fitted.height) + padding * 2
        guard height <= 16_000 else { throw DocumentError.textTooLong }
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw DocumentError.layoutFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let path = CGPath(rect: CGRect(x: padding, y: padding, width: width - padding * 2, height: height - padding * 2), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        guard let image = context.makeImage() else { throw DocumentError.layoutFailed }
        return image
    }
}
