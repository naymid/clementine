import AppKit
import SwiftUI

/// Renders views offscreen to PNG, for design checks without a visible display.
/// Usage: Clementine --snapshot <name> <out.png> [--dark] [--files a:b:c] [--hover N]
@MainActor
enum Snapshot {
    static func run(_ arguments: [String]) {
        guard arguments.count > 3 else { return }
        let name = arguments[2]
        let output = URL(fileURLWithPath: arguments[3])
        let dark = arguments.contains("--dark")
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let files = (value("--files") ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let hover = value("--hover").flatMap(Int.init)
        let size = value("--size").map { $0.split(separator: "x").compactMap { Double($0) } }

        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view: AnyView
        var canvas = CGSize(width: 420, height: 420)
        switch name {
        case "wheel", "tools":
            let controller = WheelController.shared
            let model = controller.model
            model.style = value("--style").flatMap(WheelStyle.init(rawValue:)) ?? .solid
            controller.configureForSnapshot(mode: name == "tools" ? .tools : .convert, urls: files)
            model.isPresented = true
            model.hovered = hover
            view = AnyView(WheelView(model: model).padding(40))
        default:
            if let custom = SnapshotRegistry.view(named: name, files: files, arguments: arguments) {
                view = custom.view
                canvas = custom.size
            } else {
                print("unknown snapshot \(name)")
                exit(2)
            }
        }
        if let size, size.count == 2 { canvas = CGSize(width: size[0], height: size[1]) }
        let background = dark ? Color(white: 0.16) : Color(white: 0.93)
        let root = view
            .frame(width: canvas.width, height: canvas.height)
            .background(background)
            .environment(\.colorScheme, dark ? .dark : .light)
        render(root, size: canvas, dark: dark, to: output)
    }

    static func render<V: View>(_ view: V, size: CGSize, dark: Bool, to output: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        let wait = ProcessInfo.processInfo.environment["SNAPSHOT_WAIT"].flatMap(Double.init) ?? 0.8
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: output)
        print(output.path)
        exit(0)
    }
}

/// Additional named views for snapshots, filled in by other parts of the app.
@MainActor
enum SnapshotRegistry {
    struct Entry {
        var view: AnyView
        var size: CGSize
    }

    static var builders: [String: ([URL], [String]) -> Entry] = [:]

    static func view(named name: String, files: [URL], arguments: [String]) -> Entry? {
        registerAll()
        return builders[name]?(files, arguments)
    }
}

extension WheelController {
    func configureForSnapshot(mode: WheelMode, urls: [URL]) {
        present(mode: mode, urls: urls, at: NSPoint(x: -20_000, y: -20_000))
    }
}
