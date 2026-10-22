import Foundation
import CoreGraphics

/// Writes minimal Word documents: images and plain paragraphs on US Letter pages.
enum DocxWriter {
    enum Block {
        case paragraph(String)
        case image(CGImage)
        case pageBreak
    }

    static func write(images: [CGImage], to output: URL) throws {
        var blocks: [Block] = []
        for (index, image) in images.enumerated() {
            if index > 0 { blocks.append(.pageBreak) }
            blocks.append(.image(image))
        }
        try write(blocks: blocks, to: output)
    }

    static func write(blocks: [Block], to output: URL) throws {
        let fm = FileManager.default
        let root = try FileNaming.temporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        for dir in ["_rels", "word/_rels", "word/media", "docProps"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }

        var body = ""
        var relationships = ""
        var imageIndex = 0
        let maxWidth = 6_858_000.0   // 7.5 in in EMU
        let maxHeight = 9_144_000.0  // 10 in in EMU
        for block in blocks {
            switch block {
            case .pageBreak:
                body += #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#
            case .paragraph(let text):
                let runs = text.components(separatedBy: "\n").map { line in
                    #"<w:r><w:t xml:space="preserve">\#(escape(line))</w:t></w:r>"#
                }.joined(separator: "<w:r><w:br/></w:r>")
                body += "<w:p>\(runs)</w:p>"
            case .image(let image):
                imageIndex += 1
                guard let data = ImageIOHelpers.pngData(image) else { continue }
                try data.write(to: root.appendingPathComponent("word/media/image\(imageIndex).png"))
                let rid = "rId\(imageIndex + 10)"
                relationships += #"<Relationship Id="\#(rid)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image\#(imageIndex).png"/>"#
                var cx = Double(image.width) * 9525
                var cy = Double(image.height) * 9525
                let scale = min(1, maxWidth / cx, maxHeight / cy)
                cx = (cx * scale).rounded()
                cy = (cy * scale).rounded()
                body += """
                <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(Int(cx))" cy="\(Int(cy))"/>\
                <wp:docPr id="\(imageIndex)" name="Picture \(imageIndex)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
                <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
                <pic:nvPicPr><pic:cNvPr id="\(imageIndex)" name="image\(imageIndex).png"/><pic:cNvPicPr/></pic:nvPicPr>\
                <pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
                <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(Int(cx))" cy="\(Int(cy))"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
                </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
                """
            }
        }

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)\
        <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="720" w:right="720" w:bottom="720" w:left="720" w:header="0" w:footer="0" w:gutter="0"/></w:sectPr>\
        </w:body></w:document>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        </Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        </Relationships>
        """
        let documentRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relationships)</Relationships>
        """
        let core = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:creator>Clementine</dc:creator></cp:coreProperties>
        """
        try contentTypes.write(to: root.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rootRels.write(to: root.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try documentRels.write(to: root.appendingPathComponent("word/_rels/document.xml.rels"), atomically: true, encoding: .utf8)
        try document.write(to: root.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try core.write(to: root.appendingPathComponent("docProps/core.xml"), atomically: true, encoding: .utf8)

        try zip(directory: root, entries: ["[Content_Types].xml", "_rels", "docProps", "word"], to: output)
    }

    /// Zips `entries` (relative to `directory`) with /usr/bin/zip.
    static func zip(directory: URL, entries: [String], to output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-X", "-r", "-q", output.path] + entries
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ImageError.writeFailed("Could not write the DOCX file.") }
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default:
                // XML 1.0 forbids most control characters.
                if scalar.value < 0x20 && scalar != "\t" { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
