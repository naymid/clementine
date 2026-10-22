import AppKit
import PDFKit
import SwiftUI

/// Merge PDFs: a reorderable list of documents, joined in order into "<first>-merged.pdf".
struct MergePDFEditorView: View {
    @ObservedObject var session: ToolSession

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var url: URL
        var cover: CGImage?
        var pageCount: Int?
    }

    @State private var items: [Item]
    @State private var uniformWidth = false
    @State private var dragging: UUID?

    init(session: ToolSession) {
        self.session = session
        _items = State(initialValue: session.urls.map { Item(url: $0) })
    }

    private var totalPages: Int { items.compactMap(\.pageCount).reduce(0, +) }
    private var unreadable: [Item] { items.filter { $0.pageCount == 0 } }

    var body: some View {
        ToolScaffold(session: session) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Drag files to set the order. Pages are joined top to bottom.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { items.sort { GeneralOrdering.finderOrder($0.url, $1.url) } }
                    } label: {
                        Label("Sort by Name", systemImage: "arrow.up.arrow.down")
                    }
                    .buttonStyle(TintedButtonStyle())
                    .help("Order the files by name, as Finder lists them")
                    .accessibilityIdentifier("sortSourcesByName")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider().opacity(0.5)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                            MergeFileRow(item: item, position: position, canRemove: items.count > 2, isDragging: dragging == item.id,
                                         move: { offset in move(item.id, by: offset) },
                                         remove: { withAnimation { items.removeAll { $0.id == item.id } } })
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
                    .accessibilityIdentifier("orderedSourceList")
                }
                .onDrop(of: [.text], delegate: GeneralReorderEndDelegate(dragging: $dragging))
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 6) {
                    GeneralToggleRow(title: PDFToolText.sameWidth, note: PDFToolText.sameWidthNote, isOn: $uniformWidth)
                    if let bad = unreadable.first {
                        GeneralWarningText(text: "\(bad.url.lastPathComponent): \(DocumentError.unreadablePDF.localizedDescription)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            ToolFooter(session: session, primaryTitle: "Merge PDFs", primaryEnabled: items.count >= 2 && unreadable.isEmpty, action: run) {
                Text("\(items.count) files · \(totalPages) pages")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .task { await loadCovers() }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, from + offset), items.count - 1)
        guard to != from else { return }
        withAnimation(.easeInOut(duration: 0.18)) { items.swapAt(from, to) }
    }

    private func loadCovers() async {
        for item in items where item.pageCount == nil {
            let (cover, count) = await GeneralThumbnails.pdfCover(item.url, maxDimension: 120)
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].cover = cover
                items[index].pageCount = count
            }
        }
    }

    private func run() {
        let ordered = items.map(\.url)
        let uniform = uniformWidth
        session.runBatch(successTitle: { _ in "Merged \(ordered.count) PDFs" }) { _, context in
            [try PDFTools.merge(ordered, uniformWidth: uniform, context: context)]
        }
    }
}

/// A document in the merge list: handle, first page, name, page count, move and remove.
struct MergeFileRow: View {
    var item: MergePDFEditorView.Item
    var position: Int
    var canRemove: Bool
    var isDragging: Bool
    var move: (Int) -> Void
    var remove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .help("Drag to reorder")
            Text("\(position + 1)")
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16)
            GeneralThumbnailCard(image: item.cover)
                .frame(width: 40, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.pageCount.map { $0 == 0 ? "Unreadable" : "\($0) page\($0 == 1 ? "" : "s")" } ?? "Reading…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(item.pageCount == 0 ? Color.orange : Color.secondary)
            }
            Spacer(minLength: 8)
            if hovering {
                GeneralIconButton(symbol: "chevron.up", help: "Move up") { move(-1) }
                GeneralIconButton(symbol: "chevron.down", help: "Move down") { move(1) }
            }
            Button(action: remove) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(canRemove ? Color.secondary : Color.secondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .help(canRemove ? "Remove from the merge" : "Merging needs at least two PDFs")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isDragging ? Brand.buttonOrange : Color.clear, lineWidth: 2))
        .opacity(isDragging ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(position + 1). \(item.url.lastPathComponent)")
    }
}
