import AppKit
import SwiftUI

/// Create PDF: images in a reorderable grid become one page each.
struct CreatePDFEditorView: View {
    @ObservedObject var session: ToolSession

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var url: URL
        var thumbnail: CGImage?
    }

    enum Margin: Int, CaseIterable, Hashable {
        case none = 0, small = 18, large = 36
        var title: String {
            switch self {
            case .none: return "None"
            case .small: return "Small"
            case .large: return "Large"
            }
        }
    }

    @State private var items: [Item]
    @State private var paper: PDFPaperSize = .fit
    @State private var margin: Margin = .none
    @State private var uniformWidth = false
    @State private var dragging: UUID?

    init(session: ToolSession, paper: PDFPaperSize = .fit) {
        self.session = session
        _items = State(initialValue: session.urls.map { Item(url: $0) })
        _paper = State(initialValue: paper)
        _margin = State(initialValue: paper == .fit ? .none : .small)
    }

    var body: some View {
        ToolScaffold(session: session) {
            VStack(spacing: 0) {
                settings
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                Divider().opacity(0.5)
                grid
            }
        } footer: {
            ToolFooter(session: session, primaryTitle: "Create PDF", primaryEnabled: !items.isEmpty, action: run) {
                Text(items.count == 1 ? "1 page" : "\(items.count) pages")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .task { await loadThumbnails() }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolSettingRow("Page size") {
                ToolSegmented(selection: $paper.animation(.easeInOut(duration: 0.15)), options: PDFPaperSize.allCases.map { ($0, $0.title) })
            }
            ToolSettingRow("Margin") {
                ToolSegmented(selection: $margin, options: Margin.allCases.map { ($0, $0.title) })
            }
            if paper == .fit {
                GeneralToggleRow(title: PDFToolText.sameWidth, note: PDFToolText.sameWidthNote, isOn: $uniformWidth)
            } else {
                Text("Each page turns to match its image, which is fitted inside the margin.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Drag images to set the page order.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { items.sort { GeneralOrdering.finderOrder($0.url, $1.url) } }
                } label: {
                    Label("Sort by Name", systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(TintedButtonStyle())
                .help("Order the files by name, as Finder lists them")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 150), spacing: 14)], spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                        CreatePDFTile(item: item, position: position, paper: paper, margin: CGFloat(margin.rawValue),
                                      canRemove: items.count > 1, isDragging: dragging == item.id) {
                            withAnimation(.easeInOut(duration: 0.2)) { items.removeAll { $0.id == item.id } }
                        }
                        .onDrag {
                            dragging = item.id
                            return NSItemProvider(object: item.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: GeneralReorderDelegate(target: item.id, dragging: $dragging) { dragged, target in
                            GeneralOrdering.move(&items, id: \.id, dragged: dragged, target: target)
                        })
                    }
                }
                .padding(16)
            }
            .onDrop(of: [.text], delegate: GeneralReorderEndDelegate(dragging: $dragging))
        }
    }

    private func loadThumbnails() async {
        for item in items where item.thumbnail == nil {
            let image = await GeneralThumbnails.image(item.url, maxPixel: 300)
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].thumbnail = image }
        }
    }

    private func run() {
        let images = items.map(\.url)
        let paper = paper, margin = CGFloat(margin.rawValue), uniform = uniformWidth && paper == .fit
        session.runBatch(successTitle: { _ in "Created PDF" }) { _, context in
            [try PDFTools.createPDF(images: images, paper: paper, margin: margin, uniformWidth: uniform, context: context)]
        }
    }
}

/// An image as a page preview: white paper with the image fitted inside the margin.
struct CreatePDFTile: View {
    var item: CreatePDFEditorView.Item
    var position: Int
    var paper: PDFPaperSize
    var margin: CGFloat
    var canRemove: Bool
    var isDragging: Bool
    var remove: () -> Void

    @State private var hovering = false

    private var pageAspect: CGFloat {
        let imageAspect = item.thumbnail.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 0.75
        guard let portrait = paper.portrait else { return imageAspect }
        return imageAspect > 1 ? portrait.height / portrait.width : portrait.width / portrait.height
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = min(proxy.size.width, proxy.size.height * pageAspect)
                let height = width / pageAspect
                let paperLong = paper.portrait.map { max($0.width, $0.height) } ?? max(width, height)
                let inset = paper == .fit ? (margin > 0 ? 4 : 0) : margin / paperLong * max(width, height)
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    if let thumbnail = item.thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(inset)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: width, height: height)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(height: 132)
            .overlay(alignment: .topTrailing) {
                if hovering && canRemove {
                    GeneralIconButton(symbol: "xmark", help: "Remove image", action: remove)
                        .offset(x: 4, y: -6)
                }
            }
            HStack(spacing: 4) {
                Text("\(position + 1)")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                Text(item.url.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.primary.opacity(0.06) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isDragging ? Brand.buttonOrange : Color.clear, lineWidth: 2))
        .opacity(isDragging ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("Page \(position + 1): \(item.url.lastPathComponent). Drag to reorder.")
    }
}
