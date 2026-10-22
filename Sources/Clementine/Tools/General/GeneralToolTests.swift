import AppKit

/// Headless tests: `Clementine --tool-test <name> <files…> [key=value…]`.
extension GeneralTools {
    static func registerTests() {
        // compress strength=balanced|strong size=original|2560|1920|1280 height=720 target=200KB
        ToolTestRegistry.tests["compress"] = { files, options, context in
            var request = CompressionRequest()
            if let strength = options["strength"].flatMap(CompressionStrength.init(rawValue:)) { request.strength = strength }
            if let size = GeneralTestOptions.int(options, "size"), let limit = ImageSizeLimit(rawValue: size) { request.imageSize = limit }
            request.maxVideoHeight = GeneralTestOptions.int(options, "height") ?? 0
            request.targetBytes = options["target"].flatMap(GeneralSizeText.parse)
            var outputs: [URL] = []
            var failures = 0
            for file in files {
                do {
                    let output = try await FileCompressor.compress(file, request: request, context: context)
                    print("compress: \(file.lastPathComponent) \(GeneralSizeText.bytes(of: file)) -> \(output.lastPathComponent) \(GeneralSizeText.bytes(of: output)) bytes")
                    outputs.append(output)
                } catch {
                    failures += 1
                    print("compress: \(file.lastPathComponent) FAILED: \(error.localizedDescription)")
                }
            }
            if failures > 0 && outputs.isEmpty { throw GeneralToolFailure("\(failures) file(s) failed") }
            return outputs
        }

        // removeMetadata [mode=list|all|edit] [remove=<id>,<id>|gps|sensitive] [set:<id>=value]
        ToolTestRegistry.tests["removeMetadata"] = { files, options, context in
            var outputs: [URL] = []
            let mode = options["mode"] ?? "all"
            var failures = 0
            for file in files {
                do {
                    if let output = try await metadataTest(file, mode: mode, options: options, context: context) { outputs.append(output) }
                } catch {
                    failures += 1
                    print("removeMetadata: \(file.lastPathComponent) FAILED: \(error.localizedDescription)")
                }
            }
            if failures > 0 && outputs.isEmpty && mode != "list" { throw GeneralToolFailure("\(failures) file(s) failed") }
            return outputs
        }

        // splitPDF mode=everyPage|everyN|custom n=3 ranges="1-3,4,7-9"
        ToolTestRegistry.tests["splitPDF"] = { files, options, context in
            guard let file = files.first else { throw GeneralToolFailure("Pass a PDF.") }
            let mode = options["mode"].flatMap(PDFSplitMode.init(rawValue:)) ?? .everyPage
            let count = try PDFTools.open(file).pageCount
            let ranges = try PDFTools.splitRanges(mode: mode, every: GeneralTestOptions.int(options, "n") ?? 2,
                                                  custom: options["ranges"] ?? "", pageCount: count)
            print("splitPDF: \(ranges.map(PDFTools.rangeLabel).joined(separator: ", ")) → \(ranges.count) files")
            return try PDFTools.split(file, ranges: ranges, context: context)
        }

        // organizePDF order=3,1,2 (1-based; omitted pages are deleted) rotate=3:90,1:-90 uniform=1
        ToolTestRegistry.tests["organizePDF"] = { files, options, context in
            guard let file = files.first else { throw GeneralToolFailure("Pass a PDF.") }
            let count = try PDFTools.open(file).pageCount
            let order = GeneralTestOptions.list(options, "order").compactMap(Int.init)
            var rotations: [Int: Int] = [:]
            for item in GeneralTestOptions.list(options, "rotate") {
                let parts = item.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2 { rotations[parts[0]] = parts[1] }
            }
            let pages = (order.isEmpty ? Array(1...count) : order).map { PDFTools.PageEdit(index: $0 - 1, rotation: rotations[$0] ?? 0) }
            return [try PDFTools.organize(file, pages: pages, uniformWidth: GeneralTestOptions.bool(options, "uniform"), context: context)]
        }

        // mergePDF sort=name uniform=1
        ToolTestRegistry.tests["mergePDF"] = { files, options, context in
            let ordered = options["sort"] == "name" ? files.sorted(by: GeneralOrdering.finderOrder) : files
            return [try PDFTools.merge(ordered, uniformWidth: GeneralTestOptions.bool(options, "uniform"), context: context)]
        }

        // createPDF page=fit|a4|letter margin=0|18|36 uniform=1
        ToolTestRegistry.tests["createPDF"] = { files, options, context in
            let paper = options["page"].flatMap(PDFPaperSize.init(rawValue:)) ?? .fit
            let margin = CGFloat(GeneralTestOptions.int(options, "margin") ?? 0)
            return [try PDFTools.createPDF(images: files, paper: paper, margin: margin,
                                           uniformWidth: GeneralTestOptions.bool(options, "uniform"), context: context)]
        }

        // readQRCode <images or PDFs> — prints every payload, writes nothing.
        ToolTestRegistry.tests["readQRCode"] = { files, _, _ in
            for file in files {
                let hits = try await QRCodeScanner.scan(file)
                print("readQRCode: \(file.lastPathComponent): \(hits.count) code(s)")
                for hit in hits { print("  \(hit.page.map { "page \($0): " } ?? "")\(hit.payload)") }
            }
            return []
        }

        // makeQR <out.png> text=… — writes a QR code PNG with CIQRCodeGenerator.
        ToolTestRegistry.tests["makeQR"] = { files, options, _ in
            guard let output = files.first, let image = QRCodeScanner.makeQRImage(options["text"] ?? "https://example.com") else {
                throw GeneralToolFailure("Pass an output path and text=…")
            }
            try ImageIOHelpers.write(image, to: output, format: .png, quality: nil)
            return [output]
        }

        ToolTestRegistry.tests["extractArchive"] = { files, _, context in
            var outputs: [URL] = []
            for file in files { outputs.append(try await ArchiveExtraction.extract(file, context: context)) }
            return outputs
        }
    }

    /// Lists a file's fields, applies Remove All or the given edits, and lists the result.
    private static func metadataTest(_ file: URL, mode: String, options: [String: String], context: JobContext) async throws -> URL? {
        let report = try await MetadataStore.read(file)
        printMetadata(report, title: file.lastPathComponent)
        guard mode != "list" else { return nil }
        let output: URL
        if mode == "all" {
            output = try await MetadataStore.removeAll(file, context: context)
        } else {
            var changes = MetadataChanges()
            for id in GeneralTestOptions.list(options, "remove") {
                switch id {
                case "gps": changes.removed.formUnion(report.fields.filter { $0.section == "GPS Location" }.map(\.id))
                case "sensitive": changes.removed.formUnion(report.fields.filter { $0.sensitive && $0.removable }.map(\.id))
                default: changes.removed.insert(id)
                }
            }
            for (key, value) in options where key.hasPrefix("set:") { changes.edits[String(key.dropFirst(4))] = value }
            output = try await MetadataStore.apply(changes, to: file, context: context)
        }
        printMetadata(try await MetadataStore.read(output), title: "→ " + output.lastPathComponent)
        return output
    }

    private static func printMetadata(_ report: MetadataReport, title: String) {
        print("\(title): \(report.fields.count) fields")
        for section in report.sections {
            for field in section.fields {
                let flags = (field.sensitive ? "!" : " ") + (field.editable ? "e" : " ") + (field.removable ? " " : "x")
                print("  [\(flags)] \(section.title) · \(field.label) (\(field.id)) = \(field.value.prefix(60))")
            }
        }
    }
}
