import AppKit
import ImageIO
import PDFKit

enum PDFToolText {
    static let rangeInvalid = "Set a start and end within the file."
    static let rotation = "Page rotations must be 90-degree turns for pages in this PDF."
    static let noPages = "This PDF has no pages."
    static let keepOnePage = "Keep at least one page."
    static let sameWidthNote = "Pages are scaled proportionally to match the narrowest page; their heights may still differ."
    static let sameWidth = "Make all pages the same width"
}

enum PDFSplitMode: String, CaseIterable, Hashable {
    case everyPage, everyN, custom
    var title: String {
        switch self {
        case .everyPage: return "Every page"
        case .everyN: return "Every N pages"
        case .custom: return "Custom ranges"
        }
    }
}

enum PDFPaperSize: String, CaseIterable, Hashable {
    case fit, a4, letter
    var title: String {
        switch self {
        case .fit: return "Fit image"
        case .a4: return "A4"
        case .letter: return "Letter"
        }
    }
    /// Portrait size in points.
    var portrait: CGSize? {
        switch self {
        case .fit: return nil
        case .a4: return CGSize(width: 595.28, height: 841.89)
        case .letter: return CGSize(width: 612, height: 792)
        }
    }
}

/// Split, organize, merge and create PDFs with PDFKit and Quartz.
enum PDFTools {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            throw GeneralToolFailure("\(url.lastPathComponent): \(DocumentError.unreadablePDF.localizedDescription)")
        }
        guard document.pageCount > 0 else { throw GeneralToolFailure(PDFToolText.noPages) }
        return document
    }

    // MARK: Split

    /// Page ranges (1-based, inclusive) for a split mode.
    static func splitRanges(mode: PDFSplitMode, every: Int, custom: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        guard pageCount > 0 else { throw GeneralToolFailure(PDFToolText.noPages) }
        switch mode {
        case .everyPage:
            return (1...pageCount).map { $0...$0 }
        case .everyN:
            let step = max(1, every)
            return stride(from: 1, through: pageCount, by: step).map { $0...min(pageCount, $0 + step - 1) }
        case .custom:
            return try parseRanges(custom, pageCount: pageCount)
        }
    }

    /// Parses "1-3, 4, 7-9" (also "5-" for "5 to the end").
    static func parseRanges(_ text: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        let tokens = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw GeneralToolFailure(PDFToolText.rangeInvalid) }
        return try tokens.map { token in
            let normalized = token.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            let parts = normalized.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let start: Int?, end: Int?
            switch parts.count {
            case 1: start = Int(parts[0]); end = start
            case 2: start = Int(parts[0]); end = parts[1].isEmpty ? pageCount : Int(parts[1])
            default: start = nil; end = nil
            }
            guard let start, let end, start >= 1, end >= start, end <= pageCount else {
                throw GeneralToolFailure(PDFToolText.rangeInvalid)
            }
            return start...end
        }
    }

    static func rangeLabel(_ range: ClosedRange<Int>) -> String {
        range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound)-\(range.upperBound)"
    }

    /// Writes one PDF per range: "name 1-3.pdf" beside the original, or in a "name pages" folder for more than three.
    static func split(_ url: URL, ranges: [ClosedRange<Int>], context: JobContext) throws -> [URL] {
        let source = try open(url)
        guard !ranges.isEmpty, ranges.allSatisfy({ $0.lowerBound >= 1 && $0.upperBound <= source.pageCount }) else {
            throw GeneralToolFailure(PDFToolText.rangeInvalid)
        }
        let base = FileNaming.baseName(of: url)
        let directory: URL
        let usesFolder = ranges.count > 3
        if usesFolder {
            directory = FileNaming.folder(beside: url, suffix: " pages")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } else {
            directory = url.deletingLastPathComponent()
        }
        var outputs: [URL] = []
        do {
            for (index, range) in ranges.enumerated() {
                try context.checkCancelled()
                let document = PDFDocument()
                for pageNumber in range {
                    guard let page = source.page(at: pageNumber - 1)?.copy() as? PDFPage else {
                        throw GeneralToolFailure("Could not read PDF page \(pageNumber).")
                    }
                    document.insert(page, at: document.pageCount)
                }
                document.documentAttributes = source.documentAttributes
                let output = FileNaming.uniqueURL(in: directory, base: "\(base) \(rangeLabel(range))", extension: "pdf")
                guard document.write(to: output), PDFDocument(url: output)?.pageCount == range.count else {
                    throw GeneralToolFailure("Could not write page \(range.lowerBound).")
                }
                outputs.append(output)
                context.progress(Double(index + 1) / Double(ranges.count))
            }
        } catch {
            outputs.forEach { try? FileManager.default.removeItem(at: $0) }
            if usesFolder { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
        return usesFolder ? [directory] : outputs
    }

    // MARK: Organize

    struct PageEdit: Hashable {
        /// 0-based page index in the source.
        var index: Int
        /// Extra clockwise rotation in degrees.
        var rotation: Int
    }

    static func organize(_ url: URL, pages: [PageEdit], uniformWidth: Bool, context: JobContext) throws -> URL {
        let source = try open(url)
        guard !pages.isEmpty else { throw GeneralToolFailure(PDFToolText.keepOnePage) }
        var edited: [PDFPage] = []
        for edit in pages {
            guard edit.rotation % 90 == 0 else { throw GeneralToolFailure(PDFToolText.rotation) }
            guard edit.index >= 0, edit.index < source.pageCount, let page = source.page(at: edit.index)?.copy() as? PDFPage else {
                throw GeneralToolFailure("Could not read PDF page \(edit.index + 1).")
            }
            page.rotation = ((page.rotation + edit.rotation) % 360 + 360) % 360
            edited.append(page)
        }
        let output = FileNaming.output(beside: url, suffix: "-organized", extension: "pdf")
        try write(edited, to: output, uniformWidth: uniformWidth, attributes: source.documentAttributes,
                  failure: "PDFKit could not write the organized PDF.")
        guard let check = PDFDocument(url: output), check.pageCount == pages.count else {
            try? FileManager.default.removeItem(at: output)
            throw GeneralToolFailure("The organized PDF could not be verified.")
        }
        context.progress(1)
        return output
    }

    // MARK: Merge

    static func merge(_ urls: [URL], uniformWidth: Bool, context: JobContext) throws -> URL {
        guard urls.count >= 2 else { throw GeneralToolFailure("Select at least two PDFs to merge.") }
        let documents = try urls.map(open)
        var pages: [PDFPage] = []
        for (index, document) in documents.enumerated() {
            try context.checkCancelled()
            for pageIndex in 0..<document.pageCount {
                if let page = document.page(at: pageIndex)?.copy() as? PDFPage { pages.append(page) }
            }
            context.progress(Double(index + 1) / Double(documents.count) * 0.6)
        }
        let output = FileNaming.output(beside: urls[0], suffix: "-merged", extension: "pdf")
        try write(pages, to: output, uniformWidth: uniformWidth, attributes: nil, failure: "PDFKit could not write the combined PDF.")
        guard let check = PDFDocument(url: output), check.pageCount == pages.count else {
            try? FileManager.default.removeItem(at: output)
            throw GeneralToolFailure("The PDF could not be verified.")
        }
        context.progress(1)
        return output
    }

    // MARK: Shared writing

    /// The page's size as displayed, after its rotation.
    static func displaySize(_ page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
    }

    /// Writes pages as-is with PDFKit (links and annotations kept), or redraws them scaled to the narrowest width.
    static func write(_ pages: [PDFPage], to output: URL, uniformWidth: Bool, attributes: [AnyHashable: Any]?, failure: String) throws {
        guard !pages.isEmpty else { throw GeneralToolFailure(PDFToolText.keepOnePage) }
        let widths = pages.map { displaySize($0).width }
        if !uniformWidth || Set(widths.map { Int($0.rounded()) }).count == 1 {
            let document = PDFDocument()
            for page in pages { document.insert(page, at: document.pageCount) }
            if let attributes { document.documentAttributes = attributes }
            guard document.write(to: output) else { throw GeneralToolFailure(failure) }
            return
        }
        let narrowest = widths.min() ?? 612
        var info: [CFString: Any] = [:]
        if let title = attributes?[PDFDocumentAttribute.titleAttribute.rawValue] as? String { info[kCGPDFContextTitle] = title }
        if let author = attributes?[PDFDocumentAttribute.authorAttribute.rawValue] as? String { info[kCGPDFContextAuthor] = author }
        var box = CGRect(x: 0, y: 0, width: narrowest, height: 792)
        guard let context = CGContext(output as CFURL, mediaBox: &box, info as CFDictionary) else { throw GeneralToolFailure(failure) }
        for page in pages {
            let size = displaySize(page)
            let scale = narrowest / max(size.width, 1)
            var mediaBox = CGRect(x: 0, y: 0, width: narrowest, height: (size.height * scale).rounded(.toNearestOrEven))
            context.beginPage(mediaBox: &mediaBox)
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: context)
            context.restoreGState()
            context.endPage()
        }
        context.closePDF()
    }

    // MARK: Create from images

    /// One page per image. "Fit image" pages match each image (at 144 ppi); A4 and Letter pages turn
    /// to match each image's orientation and fit it inside the margin.
    static func createPDF(images: [URL], paper: PDFPaperSize, margin: CGFloat, uniformWidth: Bool, context: JobContext) throws -> URL {
        guard let first = images.first else { throw GeneralToolFailure("Choose at least one image.") }
        var items: [(image: CGImage, orientation: Int, upright: CGSize)] = []
        for url in images {
            try context.checkCancelled()
            items.append(try loadOriented(url))
        }
        let output = FileNaming.output(beside: first, extension: "pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(output as CFURL, mediaBox: &box, nil) else { throw GeneralToolFailure("Could not create the PDF.") }
        // Fit pages: pixels at 144 ppi, optionally scaled to the narrowest image.
        let fitSizes = items.map { CGSize(width: $0.upright.width / 2, height: $0.upright.height / 2) }
        let narrowest = fitSizes.map(\.width).min() ?? 612
        for (index, item) in items.enumerated() {
            var pageSize: CGSize
            var contentRect: CGRect
            if let portrait = paper.portrait {
                let landscape = item.upright.width > item.upright.height
                pageSize = landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
                let available = CGRect(origin: .zero, size: pageSize).insetBy(dx: margin, dy: margin)
                let scale = min(available.width / item.upright.width, available.height / item.upright.height)
                let size = CGSize(width: item.upright.width * scale, height: item.upright.height * scale)
                contentRect = CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2, width: size.width, height: size.height)
            } else {
                var size = fitSizes[index]
                if uniformWidth { size = CGSize(width: narrowest, height: size.height * narrowest / size.width) }
                pageSize = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
                contentRect = CGRect(x: margin, y: margin, width: size.width, height: size.height)
            }
            var mediaBox = CGRect(origin: .zero, size: pageSize)
            pdf.beginPage(mediaBox: &mediaBox)
            if margin > 0 || paper != .fit {
                pdf.setFillColor(CGColor(gray: 1, alpha: 1))
                pdf.fill(mediaBox)
            }
            pdf.interpolationQuality = .high
            drawOriented(item.image, orientation: item.orientation, in: contentRect, context: pdf)
            pdf.endPage()
            context.progress(Double(index + 1) / Double(items.count))
        }
        pdf.closePDF()
        guard let check = PDFDocument(url: output), check.pageCount == items.count else {
            try? FileManager.default.removeItem(at: output)
            throw GeneralToolFailure("The PDF could not be verified.")
        }
        return output
    }

    /// The stored image plus its EXIF orientation. Keeping the stored (often JPEG) image lets Quartz
    /// embed it without re-compressing.
    private static func loadOriented(_ url: URL) throws -> (image: CGImage, orientation: Int, upright: CGSize) {
        if url.pathExtension.lowercased() == "svg" {
            let image = try ImageIOHelpers.load(url).image
            return (image, 1, CGSize(width: image.width, height: image.height))
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw GeneralToolFailure("Could not read the image \(url.lastPathComponent).")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? Int).flatMap { (1...8).contains($0) ? $0 : nil } ?? 1
        let upright = orientation >= 5 ? CGSize(width: image.height, height: image.width) : CGSize(width: image.width, height: image.height)
        return (image, orientation, upright)
    }

    /// Draws a stored image so it appears upright in `rect`, applying its EXIF orientation.
    static func drawOriented(_ image: CGImage, orientation: Int, in rect: CGRect, context: CGContext) {
        let w = rect.width, h = rect.height
        let transform: CGAffineTransform
        switch orientation {
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: w, ty: h)
        case 6: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: h)
        case 7: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: w, ty: 0)
        default: transform = .identity
        }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.concatenate(transform)
        let drawSize = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        context.draw(image, in: CGRect(origin: .zero, size: drawSize))
        context.restoreGState()
    }
}
