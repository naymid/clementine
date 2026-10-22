import AppKit
import PDFKit
import SwiftUI

/// Split PDF: every page, every N pages, or custom ranges, with a live preview of
/// which pages land in which file.
struct SplitPDFEditorView: View {
    @ObservedObject var session: ToolSession

    @State private var mode: PDFSplitMode
    @State private var every = 2
    @State private var custom: String
    @State private var thumbnails: [CGImage?] = []
    @State private var pageCount: Int
    @State private var unreadable = false

    static let groupColors: [Color] = [Brand.buttonOrange, .blue, .purple, .teal, .pink, .green, .indigo, .brown]

    init(session: ToolSession, mode: PDFSplitMode = .everyPage, custom: String = "") {
        self.session = session
        let count = PDFDocument(url: session.primaryURL)?.pageCount ?? 0
        _pageCount = State(initialValue: count)
        _mode = State(initialValue: mode)
        _custom = State(initialValue: custom.isEmpty ? (count > 1 ? "1-\(max(1, count / 2)), \(count / 2 + 1)-\(count)" : "1") : custom)
    }

    private var rangesResult: Result<[ClosedRange<Int>], Error> {
        Result { try PDFTools.splitRanges(mode: mode, every: every, custom: custom, pageCount: pageCount) }
    }

    private var ranges: [ClosedRange<Int>] { (try? rangesResult.get()) ?? [] }

    /// Output file index for each 1-based page (custom ranges may repeat or skip pages).
    private var groupOfPage: [Int: Int] {
        var map: [Int: Int] = [:]
        for (index, range) in ranges.enumerated() {
            for page in range where map[page] == nil { map[page] = index }
        }
        return map
    }

    var body: some View {
        ToolScaffold(session: session) {
            if unreadable || pageCount == 0 {
                ToolMessageView(symbol: "exclamationmark.triangle", message: DocumentError.unreadablePDF.localizedDescription)
            } else {
                VStack(spacing: 0) {
                    settings
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    Divider().opacity(0.5)
                    pageGrid
                }
            }
        } footer: {
            ToolFooter(session: session, primaryTitle: "Split PDF", primaryEnabled: !ranges.isEmpty, action: run) {
                Text("\(pageCount) page\(pageCount == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            guard thumbnails.isEmpty else { return }
            thumbnails = await GeneralThumbnails.pdfPages(session.primaryURL, maxDimension: 220)
            if thumbnails.isEmpty { unreadable = true }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolSegmented(selection: $mode.animation(.easeInOut(duration: 0.15)),
                          options: PDFSplitMode.allCases.map { ($0, $0.title) })
            switch mode {
            case .everyPage:
                EmptyView()
            case .everyN:
                HStack(spacing: 8) {
                    Text("Pages per file").font(.system(size: 13))
                    TextField("Pages", value: Binding(get: { every }, set: { every = min(max(1, $0), max(1, pageCount)) }),
                              format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 54)
                        .multilineTextAlignment(.trailing)
                    Stepper("Pages per file", value: $every, in: 1...max(1, pageCount))
                        .labelsHidden()
                }
            case .custom:
                VStack(alignment: .leading, spacing: 4) {
                    TextField("1-3, 4, 7-9", text: $custom)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13).monospacedDigit())
                        .accessibilityLabel("Page ranges")
                    Text("One file per range. Separate ranges with commas, for example 1-3, 4, 7-9.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            summary
        }
    }

    @ViewBuilder
    private var summary: some View {
        switch rangesResult {
        case .failure(let error):
            GeneralWarningText(text: error.localizedDescription)
        case .success(let ranges):
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(Brand.buttonOrange)
                Text(ranges.count == 1 ? "Creates 1 file" : "Creates \(ranges.count) files")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(ranges.count > 3 ? "in a “\(FileNaming.baseName(of: session.primaryURL)) pages” folder"
                                      : ranges.map { "\(FileNaming.baseName(of: session.primaryURL)) \(PDFTools.rangeLabel($0)).pdf" }
                                          .joined(separator: ", "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var pageGrid: some View {
        let groups = groupOfPage
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 12)], spacing: 14) {
                ForEach(1...max(1, pageCount), id: \.self) { page in
                    let group = groups[page]
                    let color = group.map { Self.groupColors[$0 % Self.groupColors.count] }
                    VStack(spacing: 5) {
                        GeneralThumbnailCard(image: page - 1 < thumbnails.count ? thumbnails[page - 1] : nil)
                            .frame(height: 118)
                            .opacity(group == nil ? 0.35 : 1)
                        HStack(spacing: 5) {
                            Text("\(page)")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                            if let group {
                                Text("File \(group + 1)")
                                    .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(color ?? .gray))
                                    .help("Goes into file \(group + 1)")
                            }
                        }
                        Capsule()
                            .fill(color ?? Color.clear)
                            .frame(height: 3)
                            .padding(.horizontal, 10)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(group.map { "Page \(page), file \($0 + 1)" } ?? "Page \(page), not included")
                }
            }
            .padding(16)
        }
    }

    private func run() {
        let ranges = ranges
        guard !ranges.isEmpty else { return }
        session.runBatch(successTitle: { _ in ranges.count == 1 ? "Saved 1 PDF" : "Saved \(ranges.count) PDFs" }) { urls, context in
            try PDFTools.split(urls[0], ranges: ranges, context: context)
        }
    }
}
