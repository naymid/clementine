import AppKit
import CoreImage
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// One decoded code.
struct QRCodeHit: Identifiable, Hashable {
    let id = UUID()
    var payload: String
    /// 1-based PDF page, or nil for images.
    var page: Int?

    /// A link worth offering "Open" for.
    var openableURL: URL? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        let schemes = ["http", "https", "mailto", "tel", "sms", "facetime", "maps", "geo"]
        guard schemes.contains(scheme) else { return nil }
        if scheme.hasPrefix("http") && url.host == nil { return nil }
        return url
    }
}

/// Finds QR codes with Vision in images and rendered PDF pages.
enum QRCodeScanner {
    static func scan(_ url: URL) async throws -> [QRCodeHit] {
        try await Task.detached(priority: .userInitiated) {
            if url.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(url: url), !document.isLocked else { throw DocumentError.unreadablePDF }
                var hits: [QRCodeHit] = []
                for index in 0..<min(document.pageCount, 500) {
                    guard let page = document.page(at: index) else { continue }
                    // About 2400 px on the long edge keeps small codes readable.
                    let bounds = page.bounds(for: .cropBox)
                    let scale = min(4, max(1.5, 2400 / max(bounds.width, bounds.height, 1)))
                    guard let image = DocumentConverter.render(page, scale: scale) else { continue }
                    hits += try detect(in: image).map { QRCodeHit(payload: $0, page: index + 1) }
                }
                return hits
            }
            let image = try ImageIOHelpers.load(url).image
            var payloads = try detect(in: image)
            if payloads.isEmpty, max(image.width, image.height) > 3000 {
                // Very large photos: try again at a size Vision handles comfortably.
                payloads = try detect(in: ImageIOHelpers.resize(image, longestEdge: 2400))
            }
            return payloads.map { QRCodeHit(payload: $0, page: nil) }
        }.value
    }

    /// Payloads top to bottom, left to right, without duplicates.
    static func detect(in image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .microQR]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = (request.results ?? []).sorted {
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.05 ? $0.boundingBox.midY > $1.boundingBox.midY
                                                                   : $0.boundingBox.minX < $1.boundingBox.minX
        }
        var seen = Set<String>()
        return observations.compactMap { observation in
            guard let payload = observation.payloadStringValue, !payload.isEmpty, seen.insert(payload).inserted else { return nil }
            return payload
        }
    }

    /// A crisp QR code PNG for tests and previews.
    static func makeQRImage(_ text: String, scale: CGFloat = 12) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // White quiet zone around the code.
        let padded = scaled.composited(over: CIImage(color: .white).cropped(to: scaled.extent.insetBy(dx: -scale * 4, dy: -scale * 4)))
        return CIContext().createCGImage(padded, from: padded.extent)
    }
}

/// Read QR Codes: scans on open and lists every code per file with Copy and Open.
struct QRCodeReaderView: View {
    @ObservedObject var session: ToolSession

    struct FileResult: Identifiable {
        var id: URL { url }
        var url: URL
        var hits: [QRCodeHit] = []
        var error: String?
    }

    @State private var results: [FileResult] = []
    @State private var scanning = true
    @State private var copied: UUID?
    @State private var copiedAll = false

    private var allHits: [QRCodeHit] { results.flatMap(\.hits) }

    var body: some View {
        ToolScaffold(session: session, subtitle: subtitle) {
            if scanning && results.isEmpty {
                ToolMessageView(symbol: "qrcode.viewfinder", message: "Reading QR codes", isLoading: true)
            } else if allHits.isEmpty && !scanning {
                ToolMessageView(symbol: "qrcode", message: results.compactMap(\.error).first.map { "No QR codes found\n\($0)" } ?? "No QR codes found")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(results) { result in
                            if !result.hits.isEmpty || result.error != nil || session.urls.count > 1 {
                                fileSection(result)
                            }
                        }
                        if scanning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Reading QR codes").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        } footer: {
            ToolFooter(session: session, primaryTitle: "Done", action: { session.close() }) {
                Button(copiedAll ? "Copied" : "Copy All") { copyAll() }
                    .buttonStyle(TintedButtonStyle())
                    .disabled(allHits.isEmpty)
                    .opacity(allHits.isEmpty ? 0.5 : 1)
                    .help("Copy every QR code’s text, one per line")
            }
        }
        .task { await scan() }
    }

    private var subtitle: String {
        guard !scanning else { return session.subtitle }
        let count = allHits.count
        return count == 0 ? session.subtitle : "\(count) code\(count == 1 ? "" : "s") · \(session.subtitle)"
    }

    private func fileSection(_ result: FileResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.urls.count > 1 {
                Label(result.url.lastPathComponent, systemImage: result.url.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "photo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let error = result.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
            } else if result.hits.isEmpty {
                Text("No QR codes found").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(result.hits.enumerated()), id: \.element.id) { index, hit in
                        if index > 0 { Divider().opacity(0.4).padding(.leading, 44) }
                        hitRow(hit)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    private func hitRow(_ hit: QRCodeHit) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: hit.openableURL != nil ? "link" : "qrcode")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Brand.buttonOrange)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Brand.buttonOrange.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.payload)
                    .font(.system(size: 12.5))
                    .lineLimit(4)
                    .textSelection(.enabled)
                if let page = hit.page {
                    Text("Page \(page)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let url = hit.openableURL {
                Button("Open") { NSWorkspace.shared.open(url) }
                    .buttonStyle(TintedButtonStyle())
                    .help("Open \(url.absoluteString)")
            }
            Button(copied == hit.id ? "Copied" : "Copy") { copy(hit) }
                .buttonStyle(TintedButtonStyle())
                .frame(minWidth: 64)
                .help("Copy QR code text from \(hit.page.map { "page \($0)" } ?? "this image")")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func copy(_ hit: QRCodeHit) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hit.payload, forType: .string)
        copied = hit.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == hit.id { copied = nil } }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allHits.map(\.payload).joined(separator: "\n"), forType: .string)
        copiedAll = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedAll = false }
    }

    private func scan() async {
        guard results.isEmpty else { return }
        scanning = true
        for url in session.urls {
            var result = FileResult(url: url)
            do {
                result.hits = try await QRCodeScanner.scan(url)
            } catch {
                result.error = error.localizedDescription
            }
            results.append(result)
        }
        scanning = false
    }
}
