import AppKit
import SwiftUI

/// What a tool editor gets: the tool, its files, and ways to finish.
@MainActor
final class ToolSession: ObservableObject, Identifiable {
    let id = UUID()
    let tool: FileTool
    let urls: [URL]
    let formats: [FileFormat]
    fileprivate(set) weak var window: NSWindow?

    init(tool: FileTool, urls: [URL]) {
        self.tool = tool
        self.urls = urls
        formats = urls.compactMap(FileFormat.detect)
    }

    var primaryURL: URL { urls[0] }

    /// "photo.jpg" for one file, "3 files" for several.
    var subtitle: String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
    }

    func close() {
        window?.close()
    }

    /// Closes the editor and runs the work in the progress HUD, one file at a time.
    func runPerItem(title: String? = nil,
                    successTitle: ((_ outputs: [URL]) -> String)? = nil,
                    revealOutputs: Bool = true,
                    _ work: @escaping @Sendable (URL, JobContext) async throws -> [URL]) {
        close()
        JobCenter.shared.enqueue(Job(title: title ?? tool.workingTitle, items: urls, perItem: work,
                                     successTitle: successTitle, revealOutputs: revealOutputs))
    }

    /// Closes the editor and runs one batch over all files in the progress HUD.
    func runBatch(title: String? = nil,
                  successTitle: ((_ outputs: [URL]) -> String)? = nil,
                  revealOutputs: Bool = true,
                  _ work: @escaping @Sendable ([URL], JobContext) async throws -> [URL]) {
        close()
        JobCenter.shared.enqueue(Job(title: title ?? tool.workingTitle, items: urls, batch: work,
                                     successTitle: successTitle, revealOutputs: revealOutputs))
    }
}

/// An editor view plus how its window should be sized.
struct ToolEditor {
    var view: AnyView
    var size: CGSize
    var minSize: CGSize?
    var resizable: Bool = true

    init<V: View>(_ view: V, size: CGSize, minSize: CGSize? = nil, resizable: Bool = true) {
        self.view = AnyView(view)
        self.size = size
        self.minSize = minSize
        self.resizable = resizable
    }
}

/// A tool group (images, video, audio, general) provides editors for its tools.
@MainActor
protocol ToolGroup {
    static var tools: Set<FileTool> { get }
    /// An editor window for the tool, or nil to run `runImmediately` instead.
    static func makeEditor(for session: ToolSession) -> ToolEditor?
    /// Work for tools that act straight from the wheel without an editor.
    static func runImmediately(_ session: ToolSession)
    /// Named views for `--snapshot` design checks.
    static func registerSnapshots()
}

@MainActor
final class ToolCoordinator {
    static let shared = ToolCoordinator()
    static let groups: [ToolGroup.Type] = [ImageTools.self, VideoTools.self, AudioTools.self, GeneralTools.self]

    private var controllers: [UUID: ToolWindowController] = [:]

    func open(_ tool: FileTool, urls: [URL]) {
        let session = ToolSession(tool: tool, urls: urls)
        guard let group = Self.groups.first(where: { $0.tools.contains(tool) }) else {
            presentUnavailable(session)
            return
        }
        if let editor = group.makeEditor(for: session) {
            let controller = ToolWindowController(session: session, editor: editor) { [weak self] in
                self?.controllers[session.id] = nil
            }
            controllers[session.id] = controller
            controller.show()
        } else {
            group.runImmediately(session)
        }
    }

    func showUnavailable(_ session: ToolSession) { presentUnavailable(session) }

    private func presentUnavailable(_ session: ToolSession) {
        let editor = ToolEditor(ToolScaffold(session: session) {
            ToolMessageView(symbol: "hammer", message: "\(session.tool.title) isn’t available yet.")
        } footer: {
            ToolFooter(session: session, primaryTitle: nil) {}
        }, size: CGSize(width: 420, height: 260), resizable: false)
        let controller = ToolWindowController(session: session, editor: editor) { [weak self] in
            self?.controllers[session.id] = nil
        }
        controllers[session.id] = controller
        controller.show()
    }
}

/// Hosts one editor in a window with a hidden title bar; the header acts as the drag area.
@MainActor
final class ToolWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let onClose: () -> Void

    init(session: ToolSession, editor: ToolEditor, onClose: @escaping () -> Void) {
        self.onClose = onClose
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if editor.resizable { style.insert(.resizable) }
        window = NSWindow(contentRect: NSRect(origin: .zero, size: editor.size), styleMask: style, backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = session.tool.title
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        if let minSize = editor.minSize { window.contentMinSize = minSize }
        window.contentView = NSHostingView(rootView: editor.view.environmentObject(session))
        session.window = window
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Stop any media playback the editor left running.
        NotificationCenter.default.post(name: .toolWindowWillClose, object: window)
        onClose()
    }
}

extension Notification.Name {
    static let toolWindowWillClose = Notification.Name("ClementineToolWindowWillClose")
}

/// Headless entry points for testing tool processing: `Clementine --tool-test <name> <files…> [key=value…]`.
@MainActor
enum ToolTestRegistry {
    static var tests: [String: (_ files: [URL], _ options: [String: String], _ context: JobContext) async throws -> [URL]] = [:]

    static func run(_ arguments: [String]) {
        guard arguments.count > 2 else { return }
        for group in ToolCoordinator.groups { group.registerSnapshots() }
        let name = arguments[2]
        var files: [URL] = []
        var options: [String: String] = [:]
        for argument in arguments.dropFirst(3) {
            if let equals = argument.firstIndex(of: "="), !argument.hasPrefix("/") {
                options[String(argument[..<equals])] = String(argument[argument.index(after: equals)...])
            } else {
                files.append(URL(fileURLWithPath: argument))
            }
        }
        guard let test = tests[name] else {
            print("no tool test named \(name). Known: \(tests.keys.sorted().joined(separator: ", "))")
            exit(2)
        }
        Task { @MainActor in
            do {
                let outputs = try await test(files, options, JobContext())
                outputs.forEach { print($0.path) }
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
}
