import AppKit
import PDFKit
import SwiftUI

/// Organize PDF: drag pages to reorder, rotate or delete them, optionally match widths.
struct OrganizePDFEditorView: View {
    @ObservedObject var session: ToolSession

    struct PageItem: Identifiable, Equatable {
        let id = UUID()
        var index: Int
        var rotation = 0
    }

    @State private var pages: [PageItem]
    @State private var thumbnails: [CGImage?] = []
    @State private var uniformWidth = false
    @State private var dragging: UUID?
    @State private var originalCount: Int

    init(session: ToolSession, initialPages: [PageItem]? = nil) {
        self.session = session
        let count = PDFDocument(url: session.primaryURL)?.pageCount ?? 0
        _originalCount = State(initialValue: count)
        _pages = State(initialValue: initialPages ?? (0..<count).map { PageItem(index: $0) })
    }

    private var isModified: Bool {
        pages.count != originalCount || pages.enumerated().contains { $0.element.index != $0.offset || $0.element.rotation % 360 != 0 }
    }

    var body: some View {
        ToolScaffold(session: session) {
            if originalCount == 0 {
                ToolMessageView(symbol: "exclamationmark.triangle", message: DocumentError.unreadablePDF.localizedDescription)
            } else {
                VStack(spacing: 0) {
                    toolbar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    Divider().opacity(0.5)
                    grid
                }
            }
        } footer: {
            ToolFooter(session: session, primaryTitle: "Save Organized PDF", primaryEnabled: !pages.isEmpty && originalCount > 0, action: run) {
                Text(pages.count == originalCount ? "\(pages.count) pages" : "\(pages.count) of \(originalCount) pages")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            guard thumbnails.isEmpty else { return }
            thumbnails = await GeneralThumbnails.pdfPages(session.primaryURL, maxDimension: 260)
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Drag to change a page’s position, or use Rotate to turn it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { pages = (0..<originalCount).map { PageItem(index: $0) } }
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(TintedButtonStyle())
                .disabled(!isModified)
                .opacity(isModified ? 1 : 0.5)
                .help("Restore the original order, rotations and pages")
                .accessibilityIdentifier("pdfOrganizerResetOrder")
            }
            GeneralToggleRow(title: PDFToolText.sameWidth, note: PDFToolText.sameWidthNote, isOn: $uniformWidth)
                .accessibilityIdentifier("pdfOrganizerEqualWidths")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 150), spacing: 14)], spacing: 16) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { position, page in
                    OrganizePageTile(page: page, position: position,
                                     image: page.index < thumbnails.count ? thumbnails[page.index] : nil,
                                     canDelete: pages.count > 1,
                                     isDragging: dragging == page.id,
                                     rotate: { degrees in rotate(page.id, by: degrees) },
                                     move: { offset in move(page.id, by: offset) },
                                     delete: { delete(page.id) })
                        .onDrag {
                            dragging = page.id
                            return NSItemProvider(object: page.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: GeneralReorderDelegate(target: page.id, dragging: $dragging) { dragged, target in
                            GeneralOrdering.move(&pages, id: \.id, dragged: dragged, target: target)
                        })
                }
            }
            .padding(16)
            .accessibilityIdentifier("pdfOrganizerGrid")
        }
        .onDrop(of: [.text], delegate: GeneralReorderEndDelegate(dragging: $dragging))
    }

    private func rotate(_ id: UUID, by degrees: Int) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { pages[index].rotation += degrees }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let from = pages.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, from + offset), pages.count - 1)
        guard to != from else { return }
        withAnimation(.easeInOut(duration: 0.2)) { pages.insert(pages.remove(at: from), at: to) }
    }

    private func delete(_ id: UUID) {
        guard pages.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.2)) { pages.removeAll { $0.id == id } }
    }

    private func run() {
        let edits = pages.map { PDFTools.PageEdit(index: $0.index, rotation: (($0.rotation % 360) + 360) % 360) }
        let uniform = uniformWidth
        session.runPerItem(successTitle: { _ in "Saved Organized PDF" }) { url, context in
            [try PDFTools.organize(url, pages: edits, uniformWidth: uniform, context: context)]
        }
    }
}

/// One page in the organizer: thumbnail, its original number, and rotate/delete buttons on hover.
struct OrganizePageTile: View {
    var page: OrganizePDFEditorView.PageItem
    var position: Int
    var image: CGImage?
    var canDelete: Bool
    var isDragging: Bool
    var rotate: (Int) -> Void
    var move: (Int) -> Void
    var delete: () -> Void

    @State private var hovering = false

    private var normalizedRotation: Int { ((page.rotation % 360) + 360) % 360 }

    var body: some View {
        VStack(spacing: 6) {
            GeneralThumbnailCard(image: image, rotation: normalizedRotation)
                .animation(.easeInOut(duration: 0.2), value: page.rotation)
                .frame(height: 140)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.06) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isDragging ? Brand.buttonOrange : Color.clear, lineWidth: 2))
                .overlay(alignment: .top) {
                    if hovering {
                        HStack(spacing: 6) {
                            GeneralIconButton(symbol: "rotate.left", help: "Rotate 90 degrees counterclockwise") { rotate(-90) }
                            GeneralIconButton(symbol: "rotate.right", help: "Rotate 90 degrees clockwise") { rotate(90) }
                            if canDelete {
                                GeneralIconButton(symbol: "trash", help: "Delete page", tint: .red) { delete() }
                            }
                        }
                        .padding(.top, 10)
                        .transition(.opacity)
                    }
                }
            HStack(spacing: 4) {
                Text("\(position + 1)")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                if page.index != position {
                    Text("· was \(page.index + 1)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if normalizedRotation != 0 {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Brand.buttonOrange)
                    Text("\(normalizedRotation)°")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Brand.buttonOrange)
                }
            }
        }
        .contentShape(Rectangle())
        .opacity(isDragging ? 0.55 : 1)
        .onHover { inside in withAnimation(.easeInOut(duration: 0.12)) { hovering = inside } }
        .contextMenu {
            Button("Rotate Left") { rotate(-90) }
            Button("Rotate Right") { rotate(90) }
            Divider()
            Button("Move Earlier") { move(-1) }
            Button("Move Later") { move(1) }
            Divider()
            Button("Delete Page", action: delete).disabled(!canDelete)
        }
        .help("Page \(position + 1), originally page \(page.index + 1). Drag to change its position, or use Rotate to turn it clockwise")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page \(position + 1), originally page \(page.index + 1)\(normalizedRotation == 0 ? "" : ", rotated \(normalizedRotation) degrees clockwise")")
    }
}
