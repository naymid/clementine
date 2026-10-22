import SwiftUI

/// Editors and immediate actions for the general tools: compression, metadata,
/// PDF tools, QR code reading and archive extraction.
@MainActor
enum GeneralTools: ToolGroup {
    static let tools: Set<FileTool> = [.compress, .removeMetadata, .splitPDF, .organizePDF, .mergePDF, .createPDF, .readQRCode, .extractArchive]

    static func makeEditor(for session: ToolSession) -> ToolEditor? {
        switch session.tool {
        case .compress:
            return ToolEditor(CompressEditorView(session: session), size: CGSize(width: 440, height: 540), minSize: CGSize(width: 400, height: 400))
        case .removeMetadata:
            return ToolEditor(MetadataEditorView(session: session), size: CGSize(width: 580, height: 620), minSize: CGSize(width: 460, height: 420))
        case .splitPDF:
            return ToolEditor(SplitPDFEditorView(session: session), size: CGSize(width: 600, height: 600), minSize: CGSize(width: 460, height: 420))
        case .organizePDF:
            return ToolEditor(OrganizePDFEditorView(session: session), size: CGSize(width: 680, height: 620), minSize: CGSize(width: 480, height: 420))
        case .mergePDF:
            return ToolEditor(MergePDFEditorView(session: session), size: CGSize(width: 540, height: 540), minSize: CGSize(width: 440, height: 400))
        case .createPDF:
            return ToolEditor(CreatePDFEditorView(session: session), size: CGSize(width: 640, height: 600), minSize: CGSize(width: 480, height: 440))
        case .readQRCode:
            return ToolEditor(QRCodeReaderView(session: session), size: CGSize(width: 500, height: 420), minSize: CGSize(width: 380, height: 300))
        default:
            return nil
        }
    }

    static func runImmediately(_ session: ToolSession) {
        switch session.tool {
        case .extractArchive:
            session.runPerItem(title: FileTool.extractArchive.workingTitle, successTitle: { outputs in
                outputs.count == 1 ? "Extracted" : "Extracted \(outputs.count) archives"
            }) { url, context in
                [try await ArchiveExtraction.extract(url, context: context)]
            }
        default:
            ToolCoordinator.shared.showUnavailable(session)
        }
    }

    static func registerSnapshots() {
        registerSnapshotVariants()
        registerTests()
    }

    /// Extra editor states for `--snapshot` design checks.
    private static func registerSnapshotVariants() {
        func entry<V: View>(_ tool: FileTool, _ files: [URL], size: CGSize, _ make: (ToolSession) -> V) -> SnapshotRegistry.Entry {
            let session = ToolSession(tool: tool, urls: files)
            return SnapshotRegistry.Entry(view: AnyView(make(session).environmentObject(session)), size: size)
        }
        SnapshotRegistry.builders["tool-compress-target"] = { files, _ in
            entry(.compress, files, size: CGSize(width: 440, height: 540)) { CompressEditorView(session: $0, startWithTarget: true) }
        }
        SnapshotRegistry.builders["tool-removeMetadata-edited"] = { files, _ in
            entry(.removeMetadata, files, size: CGSize(width: 580, height: 620)) { session in
                var changes = MetadataChanges()
                changes.removed = ["exif:GPSLatitude", "exif:GPSLongitude", "exif:GPSAltitude", "exif:GPSAltitudeRef", "exifEX:BodySerialNumber"]
                changes.edits = ["dc:title": "Sunday walk"]
                return MetadataEditorView(session: session, initialChanges: changes)
            }
        }
        SnapshotRegistry.builders["tool-splitPDF-custom"] = { files, _ in
            entry(.splitPDF, files, size: CGSize(width: 600, height: 600)) { SplitPDFEditorView(session: $0, mode: .custom, custom: "1-3, 4, 7-9") }
        }
        SnapshotRegistry.builders["tool-organizePDF-edited"] = { files, _ in
            entry(.organizePDF, files, size: CGSize(width: 680, height: 620)) { session in
                var pages = (0..<10).map { OrganizePDFEditorView.PageItem(index: $0) }
                pages.swapAt(0, 2)
                pages[0].rotation = 90
                pages[3].rotation = 180
                pages.remove(at: 5)
                return OrganizePDFEditorView(session: session, initialPages: pages)
            }
        }
        SnapshotRegistry.builders["tool-createPDF-a4"] = { files, _ in
            entry(.createPDF, files, size: CGSize(width: 640, height: 600)) { CreatePDFEditorView(session: $0, paper: .a4) }
        }
    }
}

/// Extract Archive: each archive into a new folder beside it, named after the archive.
enum ArchiveExtraction {
    static func extract(_ url: URL, context: JobContext) async throws -> URL {
        guard let format = FileFormat.detect(url), format.family == .archive else {
            throw GeneralToolFailure("This file type is not supported.")
        }
        let parent = url.deletingLastPathComponent()
        // Extract next to the archive first, so the final move stays on one volume.
        let scratch = parent.appendingPathComponent(".clementine-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        context.progress(0.05)
        try await ArchiveConverter.extract(url, format: format, into: scratch, context: context)
        try context.checkCancelled()
        context.progress(0.85)
        let fm = FileManager.default
        for junk in ["__MACOSX", ".DS_Store"] {
            try? fm.removeItem(at: scratch.appendingPathComponent(junk))
        }
        let entries = try fm.contentsOfDirectory(atPath: scratch.path)
        guard !entries.isEmpty else { throw ArchiveError.empty }
        let destination = FileNaming.uniqueURL(in: parent, base: FileNaming.baseName(of: url), extension: "")
        var isDirectory: ObjCBool = false
        if entries.count == 1, fm.fileExists(atPath: scratch.appendingPathComponent(entries[0]).path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            // A single top-level folder becomes the destination itself, avoiding "bundle/bundle".
            try fm.moveItem(at: scratch.appendingPathComponent(entries[0]), to: destination)
        } else {
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            for entry in entries {
                try fm.moveItem(at: scratch.appendingPathComponent(entry), to: destination.appendingPathComponent(entry))
            }
        }
        context.progress(1)
        return destination
    }
}
