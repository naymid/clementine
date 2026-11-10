import AppKit
import QuickLookThumbnailing
import SwiftUI

/// The Metadata tool: one file opens the field-by-field editor; several open the batch stripper.
struct MetadataToolView: View {
    @ObservedObject var session: ToolSession
    @State private var reviewOneByOne = false

    var body: some View {
        if session.urls.count > 1 && !reviewOneByOne {
            MetadataBatchView(session: session, onReview: { reviewOneByOne = true })
        } else {
            MetadataEditorView(session: session)
        }
    }
}

/// Strips metadata from many files at once, showing what each one carries.
struct MetadataBatchView: View {
    @ObservedObject var session: ToolSession
    var onReview: () -> Void

    enum Destination: Hashable { case beside, cleanFolder }

    @State private var scans: [URL: MetadataScan] = [:]
    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var destination: Destination = .beside

    private var scannedCount: Int { scans.count }
    private var isScanning: Bool { scannedCount < session.urls.count }

    var body: some View {
        ToolScaffold(session: session, subtitle: "\(session.urls.count) files") {
            VStack(spacing: 0) {
                summary
                    .padding(16)
                Divider().opacity(0.5)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.urls, id: \.self) { url in
                            row(url)
                            Divider().opacity(0.35).padding(.leading, 64)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Divider().opacity(0.5)
                options
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        } footer: {
            ToolFooter(session: session, primaryTitle: "Strip \(session.urls.count) Files", action: strip) {
                Button("Review One by One", action: onReview)
                    .buttonStyle(PlainTextButtonStyle())
                    .help("Open the field-by-field editor and edit or remove fields per file")
            }
        }
        .task { await scanAll() }
    }

    // MARK: Summary

    private var summary: some View {
        let withData = session.urls.filter { scans[$0]?.hasAnything == true }
        let counts: [(String, Int)] = [
            ("location", count(.location)), ("camera", count(.camera)), ("author", count(.author)),
            ("AI tags", count(.aiTags)), ("Content Credentials", count(.contentCredentials)), ("prompts", count(.prompt)),
        ].filter { $0.1 > 0 }
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Brand.buttonOrange.opacity(0.12))
                Image(systemName: "eraser.line.dashed")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Brand.buttonOrange)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                if isScanning {
                    Text("Scanning \(scannedCount + 1) of \(session.urls.count)…")
                        .font(.system(size: 15, weight: .semibold))
                } else if withData.isEmpty {
                    Text("No metadata found in these files")
                        .font(.system(size: 15, weight: .semibold))
                } else {
                    Text(withData.count == session.urls.count
                         ? "All \(session.urls.count) files carry metadata"
                         : "\(withData.count) of \(session.urls.count) files carry metadata")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(counts.isEmpty
                     ? "Strip saves a clean copy of every file. Originals stay unchanged; photos aren't re-compressed."
                     : counts.map { "\($0.1) with \($0.0)" }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if isScanning { ProgressView().controlSize(.small) }
        }
    }

    private func count(_ kind: PrivacyFindings) -> Int {
        session.urls.filter { scans[$0]?.findings.contains(kind) == true }.count
    }

    // MARK: Rows

    private func row(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Group {
                if let image = thumbnails[url] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(GeneralSizeText.describe(GeneralSizeText.bytes(of: url)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            badges(for: url)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func badges(for url: URL) -> some View {
        if let scan = scans[url] {
            let labels = scan.findings.labels
            if labels.isEmpty && scan.fieldCount == 0 {
                Label("Nothing found", systemImage: "checkmark.seal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 5) {
                    ForEach(labels.prefix(3), id: \.0.rawValue) { kind, label in
                        MetadataBadge(text: label, color: color(for: kind))
                    }
                    let more = max(0, labels.count - 3)
                    if more > 0 {
                        MetadataBadge(text: "+\(more)", color: .gray)
                    } else if labels.isEmpty {
                        MetadataBadge(text: scan.fieldCount == 1 ? "1 field" : "\(scan.fieldCount) fields", color: .gray)
                    }
                }
            }
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    private func color(for kind: PrivacyFindings) -> Color {
        switch kind {
        case .location: return Color(red: 0.95, green: 0.33, blue: 0.30)
        case .camera: return Color(red: 0.45, green: 0.55, blue: 0.70)
        case .author: return Color(red: 0.20, green: 0.65, blue: 0.62)
        case .aiTags: return Color(red: 0.62, green: 0.40, blue: 0.95)
        case .contentCredentials: return Color(red: 0.25, green: 0.52, blue: 0.95)
        default: return Color(red: 0.85, green: 0.38, blue: 0.75)
        }
    }

    // MARK: Options

    private var options: some View {
        HStack(spacing: 10) {
            Text("Save clean copies")
                .font(.system(size: 13))
            ToolSegmented(selection: $destination, options: [(.beside, "Beside the originals"), (.cleanFolder, "In a “Clean” folder")])
            Spacer(minLength: 0)
        }
    }

    // MARK: Work

    private func scanAll() async {
        await withTaskGroup(of: (URL, MetadataScan, NSImage?).self) { group in
            var pending = session.urls.makeIterator()
            func addNext() {
                guard let url = pending.next() else { return }
                group.addTask {
                    async let thumbnail = Self.thumbnail(for: url)
                    let scan = await MetadataScanner.scan(url)
                    return (url, scan, await thumbnail)
                }
            }
            for _ in 0..<4 { addNext() }
            for await (url, scan, thumbnail) in group {
                scans[url] = scan
                if let thumbnail { thumbnails[url] = thumbnail }
                addNext()
            }
        }
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 72, height: 72), scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }

    private func strip() {
        let destination = destination
        session.runPerItem(title: "Stripping metadata", successTitle: { outputs in
            outputs.count == 1 ? "Stripped 1 file" : "Stripped \(outputs.count) files"
        }) { url, context in
            let folder = destination == .cleanFolder ? url.deletingLastPathComponent().appendingPathComponent("Clean", isDirectory: true) : nil
            return [try await MetadataStore.removeAll(url, into: folder, context: context)]
        }
    }
}

/// A small colored capsule naming one kind of metadata.
struct MetadataBadge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
    }
}
