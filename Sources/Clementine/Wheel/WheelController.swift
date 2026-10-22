import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats the wheel under the pointer.
final class WheelPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Receives the file drag and maps the pointer to a petal.
final class WheelDropView: NSView {
    weak var controller: WheelController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func hit(for sender: NSDraggingInfo) -> WheelGeometry.Hit {
        let local = convert(sender.draggingLocation, from: nil)
        // Wheel coordinates: origin at the center, y pointing down.
        let point = CGPoint(x: local.x - bounds.midX, y: bounds.midY - local.y)
        return controller?.model.geometry.hit(point) ?? .outside
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.updateHover(hit(for: sender))
        if case .petal = hit(for: sender) { return .copy }
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.updateHover(.outside)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if case .petal = hit(for: sender) { return true }
        return false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard case .petal(let index) = hit(for: sender) else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        controller?.performDrop(index: index, urls: urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        controller?.dismiss()
    }
}

/// Shows, updates and dismisses the wheel, and dispatches drops.
@MainActor
final class WheelController {
    static let shared = WheelController()

    let model = WheelModel()
    private var panel: WheelPanel?
    private var hostingView: NSHostingView<WheelView>?
    private var urls: [URL] = []
    private var formats: [FileFormat] = []
    private(set) var isVisible = false
    private var dismissWorkItem: DispatchWorkItem?

    /// Runs the chosen action. Set by the app delegate.
    var onAction: ((WheelItem.Action, [URL]) -> Void)?
    /// Lets the Getting Started tour intercept drops of its practice files.
    var practiceInterceptor: ((WheelItem.Action, [URL]) -> Bool)?

    func present(mode: WheelMode, urls: [URL], at screenPoint: NSPoint) {
        dismissWorkItem?.cancel()
        self.urls = urls
        formats = urls.compactMap(FileFormat.detect)
        configure(mode: mode)

        let panel = self.panel ?? makePanel()
        let geometry = model.geometry
        let side = geometry.diameter + 120
        let screen = NSScreen.screens.first { NSMouseInRect(screenPoint, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: screenPoint.x - side / 2, y: screenPoint.y - side / 2)
        if let visible = screen?.visibleFrame {
            let inset: CGFloat = 60 - 8
            origin.x = min(max(origin.x, visible.minX - inset), visible.maxX - side + inset)
            origin.y = min(max(origin.y, visible.minY - inset), visible.maxY - side + inset)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: side, height: side)), display: true)
        model.style = AppSettings.shared.wheelStyle
        model.hovered = nil
        if !isVisible {
            model.isPresented = false
            panel.orderFrontRegardless()
            isVisible = true
            DispatchQueue.main.async { self.model.isPresented = true }
        }
    }

    func switchMode(_ mode: WheelMode) {
        guard isVisible, mode != model.mode else { return }
        configure(mode: mode)
        model.hovered = nil
        Feedback.highlight()
    }

    private func configure(mode: WheelMode) {
        model.mode = mode
        model.emptyMessage = nil
        switch mode {
        case .convert:
            let targets = FormatCompatibility.sharedTargets(for: formats)
            model.items = formats.count == urls.count ? targets.map(WheelItem.format) : []
            if model.items.isEmpty {
                model.emptyMessage = formats.isEmpty ? "Unsupported file type" : "No shared formats for these files"
            }
        case .tools:
            let tools = formats.count == urls.count ? FileTool.tools(for: formats) : []
            model.items = tools.map(WheelItem.tool)
            if model.items.isEmpty { model.emptyMessage = "No tools for these files" }
        }
        model.summaryTitle = summaryTitle()
        model.summarySize = FileNaming.formattedSize(urls.reduce(0) { $0 + FileNaming.size(of: $1) })
    }

    private func summaryTitle() -> String {
        guard urls.count > 1 else { return "" }
        let unique = Set(formats)
        if unique.count == 1, let format = unique.first, formats.count == urls.count {
            return "\(urls.count) \(format.label) FILES"
        }
        return "\(urls.count) FILES"
    }

    func updateHover(_ hit: WheelGeometry.Hit) {
        var newHover: Int?
        if case .petal(let index) = hit { newHover = index }
        if newHover != model.hovered {
            model.hovered = newHover
            if newHover != nil { Feedback.highlight() }
        }
    }

    func performDrop(index: Int, urls droppedURLs: [URL]) {
        guard model.items.indices.contains(index) else { return }
        let action = model.items[index].action
        let files = droppedURLs.isEmpty ? urls : droppedURLs
        Feedback.drop()
        dismiss()
        if practiceInterceptor?(action, files) == true { return }
        DispatchQueue.main.async { self.onAction?(action, files) }
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        model.isPresented = false
        model.hovered = nil
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel?.orderOut(nil)
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func makePanel() -> WheelPanel {
        let panel = WheelPanel()
        let dropView = WheelDropView(frame: .zero)
        dropView.controller = self
        let hosting = NSHostingView(rootView: WheelView(model: model))
        // Without this the hosting view's fixed 300 pt size shrinks the panel from its
        // top-left corner, and the wheel no longer opens centered under the pointer.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            hosting.centerYAnchor.constraint(equalTo: dropView.centerYAnchor),
            hosting.widthAnchor.constraint(equalTo: dropView.widthAnchor),
            hosting.heightAnchor.constraint(equalTo: dropView.heightAnchor),
        ])
        panel.contentView = dropView
        self.panel = panel
        hostingView = hosting
        return panel
    }
}
