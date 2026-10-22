import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings

enum PhotoCollageStyle: String, CaseIterable, Identifiable {
    case grid, horizontal, vertical, featured
    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "Grid"
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        case .featured: return "Featured"
        }
    }

    var symbol: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .horizontal: return "rectangle.split.3x1"
        case .vertical: return "rectangle.split.1x2"
        case .featured: return "rectangle.leadinghalf.inset.filled"
        }
    }

    var help: String {
        switch self {
        case .grid: return "Equal cells in rows and columns"
        case .horizontal: return "One row, every image the same height"
        case .vertical: return "One column, every image the same width"
        case .featured: return "The first image large, the rest beside it"
        }
    }
}

enum PhotoCollageBackground: Equatable {
    case white, black, transparent
    case custom(ImageToolColor)

    var kind: String {
        switch self {
        case .white: return "white"
        case .black: return "black"
        case .transparent: return "transparent"
        case .custom: return "custom"
        }
    }
}

enum PhotoCollageFit: String, CaseIterable, Identifiable {
    case fit, fill
    var id: String { rawValue }
    var title: String { self == .fit ? "Fit whole images" : "Fill cells (crop edges)" }
}

struct PhotoCollageSettings: Equatable {
    var style: PhotoCollageStyle = .grid
    /// Thousandths of the output's long edge.
    var spacing: Double = 12
    var padding: Double = 12
    var cornerRadius: Double = 0
    var background: PhotoCollageBackground = .white
    var fit: PhotoCollageFit = .fill
    var longEdge = 2400

    static let longEdges = [2400, 3600, 4800]

    init() {}

    init(options: [String: String]) {
        let parse = ImageToolOptions(options)
        style = PhotoCollageStyle(rawValue: parse.string("style", style.rawValue)) ?? .grid
        spacing = parse.double("spacing", spacing)
        padding = parse.double("padding", padding)
        cornerRadius = parse.double("radius", cornerRadius)
        fit = PhotoCollageFit(rawValue: parse.string("fit", fit.rawValue)) ?? .fill
        longEdge = parse.int("size", longEdge)
        switch options["background"] {
        case "black": background = .black
        case "transparent", "clear", "none": background = .transparent
        case nil, "white": background = .white
        default: background = parse.color("background").map { .custom($0) } ?? .white
        }
    }
}

// MARK: - Layout and rendering

enum PhotoCollageLayout {
    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 1 }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    /// Layout in abstract units (rows 1000 high) with the given spacing and padding.
    private static func raw(_ aspects: [CGFloat], style: PhotoCollageStyle, spacing s: CGFloat, padding p: CGFloat) -> (CGSize, [CGRect]) {
        let n = aspects.count
        guard n > 0 else { return (CGSize(width: 1, height: 1), []) }
        switch style {
        case .horizontal:
            let height: CGFloat = 1000
            var x = p
            var rects: [CGRect] = []
            for aspect in aspects {
                let width = height * aspect
                rects.append(CGRect(x: x, y: p, width: width, height: height))
                x += width + s
            }
            return (CGSize(width: x - s + p, height: height + p * 2), rects)
        case .vertical:
            let width: CGFloat = 1000
            var y = p
            var rects: [CGRect] = []
            for aspect in aspects {
                let height = width / aspect
                rects.append(CGRect(x: p, y: y, width: width, height: height))
                y += height + s
            }
            return (CGSize(width: width + p * 2, height: y - s + p), rects)
        case .grid:
            let columns = n <= 3 ? n : Int(ceil(sqrt(Double(n))))
            let rows = Int(ceil(Double(n) / Double(columns)))
            let cellHeight: CGFloat = 1000
            let cellWidth = cellHeight * min(max(median(aspects), 0.6), 1.8)
            var rects: [CGRect] = []
            for index in 0..<n {
                let row = index / columns, column = index % columns
                let inRow = min(columns, n - row * columns)
                let rowOffset = CGFloat(columns - inRow) * (cellWidth + s) / 2
                rects.append(CGRect(x: p + rowOffset + CGFloat(column) * (cellWidth + s), y: p + CGFloat(row) * (cellHeight + s),
                                    width: cellWidth, height: cellHeight))
            }
            let size = CGSize(width: p * 2 + CGFloat(columns) * cellWidth + CGFloat(columns - 1) * s,
                              height: p * 2 + CGFloat(rows) * cellHeight + CGFloat(rows - 1) * s)
            return (size, rects)
        case .featured:
            guard n > 1 else { return raw(aspects, style: .horizontal, spacing: s, padding: p) }
            let height: CGFloat = 1000
            let mainWidth = height * min(max(aspects[0], 0.6), 1.8)
            let rest = n - 1
            let columns = rest <= 3 ? 1 : 2
            let rows = Int(ceil(Double(rest) / Double(columns)))
            let cellHeight = max(10, (height - CGFloat(rows - 1) * s) / CGFloat(rows))
            let cellWidth = cellHeight * min(max(median(Array(aspects.dropFirst())), 0.6), 1.8) * (columns == 2 ? 1 : 1)
            let rightWidth = CGFloat(columns) * cellWidth + CGFloat(columns - 1) * s
            let rightX = p + mainWidth + s
            var rects = [CGRect(x: p, y: p, width: mainWidth, height: height)]
            for index in 0..<rest {
                let row = index / columns, column = index % columns
                let y = p + CGFloat(row) * (cellHeight + s)
                if columns == 2, index == rest - 1, rest % 2 == 1 {
                    rects.append(CGRect(x: rightX, y: y, width: rightWidth, height: cellHeight))
                } else {
                    rects.append(CGRect(x: rightX + CGFloat(column) * (cellWidth + s), y: y, width: cellWidth, height: cellHeight))
                }
            }
            return (CGSize(width: rightX + rightWidth + p, height: height + p * 2), rects)
        }
    }

    /// Canvas size and cell rects (top-down pixels), scaled so the long edge is `longEdge`,
    /// with spacing and padding as fractions of that long edge.
    static func layout(aspects: [CGFloat], settings: PhotoCollageSettings, longEdge: CGFloat) -> (size: CGSize, cells: [CGRect]) {
        let spacing = CGFloat(settings.spacing / 1000) * longEdge
        let padding = CGFloat(settings.padding / 1000) * longEdge
        var (size, rects) = raw(aspects, style: settings.style, spacing: 0, padding: 0)
        for _ in 0..<6 {
            let scale = longEdge / max(size.width, size.height)
            (size, rects) = raw(aspects, style: settings.style, spacing: spacing / scale, padding: padding / scale)
        }
        let scale = longEdge / max(size.width, size.height)
        let cells = rects.map { CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale) }
        return (CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded())), cells)
    }

    /// Where each image is drawn inside its cell, and the clip used for rounded corners.
    static func placement(of imageSize: CGSize, in cell: CGRect, fit: PhotoCollageFit) -> (draw: CGRect, clip: CGRect) {
        switch fit {
        case .fit:
            let rect = ImageToolDrawing.fitRect(for: imageSize, in: cell)
            return (rect, rect)
        case .fill:
            return (ImageToolDrawing.fillRect(for: imageSize, in: cell), cell)
        }
    }

    static func render(_ images: [CGImage], settings: PhotoCollageSettings, longEdge: CGFloat) -> CGImage? {
        let aspects = images.map { CGFloat($0.width) / max(CGFloat($0.height), 1) }
        let (size, cells) = layout(aspects: aspects, settings: settings, longEdge: longEdge)
        guard let context = ImageToolDrawing.makeCanvas(width: Int(size.width), height: Int(size.height)) else { return nil }
        let canvas = CGRect(origin: .zero, size: size)
        switch settings.background {
        case .white: context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(canvas)
        case .black: context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(canvas)
        case .custom(let color): context.setFillColor(color.withAlpha(1).cgColor); context.fill(canvas)
        case .transparent: break
        }
        let radius = CGFloat(settings.cornerRadius / 1000) * longEdge
        for (image, cell) in zip(images, cells) {
            let placement = placement(of: CGSize(width: image.width, height: image.height), in: cell, fit: settings.fit)
            let clip = placement.clip
            let r = min(radius, clip.width / 2, clip.height / 2)
            context.saveGState()
            context.addPath(CGPath(roundedRect: clip, cornerWidth: r, cornerHeight: r, transform: nil))
            context.clip()
            ImageToolDrawing.drawUpright(image, in: placement.draw, context: context)
            context.restoreGState()
        }
        return context.makeImage()
    }

    /// Full-size collage of `urls` (in order), saved as PNG beside the first with "-collage".
    static func process(_ urls: [URL], settings: PhotoCollageSettings, context: JobContext) async throws -> [URL] {
        guard let first = urls.first else { return [] }
        let longEdge = CGFloat(settings.longEdge)
        // Work out each cell first so every photo is decoded only as large as it is drawn.
        var sizes: [CGSize] = []
        for url in urls {
            if let size = ImageToolIO.uprightSize(of: url) {
                sizes.append(size)
            } else {
                let image = try ImageIOHelpers.load(url, maxPixel: 512).image
                sizes.append(CGSize(width: image.width, height: image.height))
            }
        }
        let aspects = sizes.map { $0.width / max($0.height, 1) }
        let cells = layout(aspects: aspects, settings: settings, longEdge: longEdge).cells
        var images: [CGImage] = []
        for (offset, url) in urls.enumerated() {
            try context.checkCancelled()
            let draw = placement(of: sizes[offset], in: cells[offset], fit: settings.fit).draw
            let needed = Int(ceil(max(draw.width, draw.height) * 1.05))
            let longest = Int(max(sizes[offset].width, sizes[offset].height))
            images.append(try ImageIOHelpers.load(url, maxPixel: min(max(needed, 64), longest)).image)
            context.progress(0.7 * Double(offset + 1) / Double(urls.count))
        }
        guard let output = render(images, settings: settings, longEdge: longEdge) else {
            throw ImageError.writeFailed("Could not create the collage.")
        }
        context.progress(0.85)
        return [try await ImageToolIO.save(output, beside: first, suffix: "-collage", forcePNG: true, context: context)]
    }
}

// MARK: - Model

@MainActor
final class PhotoCollageModel: ObservableObject {
    let urls: [URL]
    /// Indices into `urls` in collage order.
    @Published var order: [Int] { didSet { if order != oldValue { scheduleRender() } } }
    @Published var settings = PhotoCollageSettings() { didSet { if settings != oldValue { scheduleRender() } } }
    @Published private(set) var rendered: CGImage?
    @Published private(set) var thumbnails: [Int: CGImage] = [:]
    @Published private(set) var loadError: String?
    @Published var customColor = ImageToolColor(hex: 0xFFF1E6)

    private var proxies: [Int: CGImage] = [:]
    private var isRendering = false
    private var needsRender = false
    private let queue = DispatchQueue(label: "clementine.collage.render", qos: .userInteractive)
    nonisolated static let previewLongEdge: CGFloat = 1100

    init(urls: [URL]) {
        self.urls = urls
        order = Array(urls.indices)
    }

    func load() async {
        guard proxies.isEmpty else { return }
        for (offset, url) in urls.enumerated() {
            do {
                let image = try await ImageToolIO.loadAsync(url, maxPixel: 700).image
                proxies[offset] = image
                thumbnails[offset] = image
            } catch {
                loadError = error.localizedDescription
                return
            }
        }
        scheduleRender()
    }

    /// Output size for the current settings.
    var outputSize: CGSize? {
        guard proxies.count == urls.count else { return nil }
        let aspects = order.compactMap { proxies[$0] }.map { CGFloat($0.width) / max(CGFloat($0.height), 1) }
        return PhotoCollageLayout.layout(aspects: aspects, settings: settings, longEdge: CGFloat(settings.longEdge)).size
    }

    func move(_ item: Int, before target: Int) {
        guard let from = order.firstIndex(of: item), let to = order.firstIndex(of: target), from != to else { return }
        var updated = order
        updated.remove(at: from)
        updated.insert(item, at: to)
        order = updated
    }

    func move(_ item: Int, by offset: Int) {
        guard let from = order.firstIndex(of: item) else { return }
        let to = min(max(0, from + offset), order.count - 1)
        guard to != from else { return }
        var updated = order
        updated.remove(at: from)
        updated.insert(item, at: to)
        order = updated
    }

    func setBackgroundKind(_ kind: String) {
        switch kind {
        case "black": settings.background = .black
        case "transparent": settings.background = .transparent
        case "custom": settings.background = .custom(customColor)
        default: settings.background = .white
        }
    }

    func setCustomColor(_ color: ImageToolColor) {
        customColor = color
        settings.background = .custom(color)
    }

    private func scheduleRender() {
        guard proxies.count == urls.count else { return }
        if isRendering {
            needsRender = true
            return
        }
        isRendering = true
        needsRender = false
        let images = order.compactMap { proxies[$0] }
        let settings = self.settings
        queue.async { [weak self] in
            let image = PhotoCollageLayout.render(images, settings: settings, longEdge: Self.previewLongEdge)
            DispatchQueue.main.async {
                guard let self else { return }
                if let image { self.rendered = image }
                self.isRendering = false
                if self.needsRender { self.scheduleRender() }
            }
        }
    }
}

// MARK: - Editor

struct CreateCollageEditor: View {
    @ObservedObject var session: ToolSession
    @StateObject private var model: PhotoCollageModel
    @State private var dragging: Int?

    init(session: ToolSession, style: PhotoCollageStyle? = nil) {
        self.session = session
        let model = PhotoCollageModel(urls: session.urls)
        if let style { model.settings.style = style }
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ToolScaffold(session: session, subtitle: "\(session.urls.count) images") {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    preview
                    Divider().opacity(0.4)
                    orderStrip
                }
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        layoutSection
                        spacingSection
                        backgroundSection
                        outputSection
                    }
                    .padding(14)
                }
                .frame(width: 290)
            }
        } footer: {
            ToolFooter(session: session, primaryTitle: "Create Collage", primaryEnabled: model.rendered != nil, action: save) {
                if let size = model.outputSize {
                    Text("\(Int(size.width)) × \(Int(size.height)) px PNG")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await model.load() }
    }

    private var preview: some View {
        Group {
            if let image = model.rendered {
                ZStack {
                    if model.settings.background == .transparent {
                        ImageCheckerboard()
                    }
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                }
                .aspectRatio(CGFloat(image.width) / CGFloat(max(image.height, 1)), contentMode: .fit)
                .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                .padding(22)
                .accessibilityLabel("Collage preview")
            } else if let error = model.loadError {
                ToolMessageView(symbol: "exclamationmark.triangle", message: error)
            } else {
                ToolMessageView(symbol: "square.grid.2x2", message: "Loading images…", isLoading: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.03))
    }

    private var orderStrip: some View {
        HStack(spacing: 10) {
            Text("Order")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.order.enumerated()), id: \.element) { position, item in
                        thumbnail(item, position: position)
                    }
                }
                .padding(.vertical, 4)
            }
            Text("Drag to reorder")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 72)
    }

    private func thumbnail(_ item: Int, position: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let thumb = model.thumbnails[item] {
                    Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.primary.opacity(0.08)
                }
            }
            .frame(width: 54, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            Text("\(position + 1)")
                .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 15, minHeight: 15)
                .background(Circle().fill(position == 0 && model.settings.style == .featured ? Brand.buttonOrange : Color.black.opacity(0.55)))
                .padding(3)
        }
        .help(session.urls[item].lastPathComponent)
        .onDrag {
            dragging = item
            return NSItemProvider(object: String(item) as NSString)
        }
        .onDrop(of: [UTType.text], delegate: CollageReorderDelegate(item: item, model: model, dragging: $dragging))
        .contextMenu {
            Button("Move Left") { model.move(item, by: -1) }.disabled(position == 0)
            Button("Move Right") { model.move(item, by: 1) }.disabled(position == model.order.count - 1)
            Button("Make First") { model.move(item, by: -position) }.disabled(position == 0)
        }
    }

    private var layoutSection: some View {
        ToolSection("Layout") {
            HStack(spacing: 6) {
                ForEach(PhotoCollageStyle.allCases) { style in
                    let selected = model.settings.style == style
                    Button {
                        model.settings.style = style
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: style.symbol).font(.system(size: 15, weight: .medium))
                            Text(style.title).font(.system(size: 10.5)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? Brand.buttonOrange : Color.primary.opacity(0.06)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(style.help)
                    .accessibilityLabel(style.title)
                }
            }
            Picker("Images", selection: $model.settings.fit) {
                ForEach(PhotoCollageFit.allCases) { fit in
                    Text(fit.title).tag(fit)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .font(.system(size: 12))
        }
    }

    private var spacingSection: some View {
        ToolSection("Spacing") {
            ImageAdjustSlider(title: "Spacing", value: $model.settings.spacing, range: 0...60, defaultValue: 12,
                              format: { "\(Int($0.rounded()))" })
            ImageAdjustSlider(title: "Padding", value: $model.settings.padding, range: 0...80, defaultValue: 12,
                              format: { "\(Int($0.rounded()))" })
            ImageAdjustSlider(title: "Corner radius", value: $model.settings.cornerRadius, range: 0...60, defaultValue: 0,
                              format: { "\(Int($0.rounded()))" })
        }
    }

    private var backgroundSection: some View {
        ToolSection("Background") {
            Picker("Background", selection: Binding(get: { model.settings.background.kind }, set: { model.setBackgroundKind($0) })) {
                Text("White").tag("white")
                Text("Black").tag("black")
                Text("Transparent").tag("transparent")
                Text("Custom").tag("custom")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            if model.settings.background.kind == "custom" {
                ToolSettingRow("Custom color") {
                    ColorPicker("Custom color", selection: Binding(get: { model.customColor.color },
                                                                   set: { model.setCustomColor(ImageToolColor(color: $0)) }),
                                supportsOpacity: false)
                        .labelsHidden()
                }
            }
        }
    }

    private var outputSection: some View {
        ToolSection("Size") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Long edge").font(.system(size: 12))
                Picker("Long edge", selection: $model.settings.longEdge) {
                    ForEach(PhotoCollageSettings.longEdges, id: \.self) { edge in
                        Text(verbatim: "\(edge) px").tag(edge)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
        }
    }

    private func save() {
        let ordered = model.order.map { model.urls[$0] }
        let settings = model.settings
        session.runBatch { _, context in
            try await PhotoCollageLayout.process(ordered, settings: settings, context: context)
        }
    }
}

/// Live reordering while a thumbnail is dragged over another.
private struct CollageReorderDelegate: DropDelegate {
    let item: Int
    let model: PhotoCollageModel
    @Binding var dragging: Int?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            model.move(dragging, before: item)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func dropExited(info: DropInfo) {}
}
