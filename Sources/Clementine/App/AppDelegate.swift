import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var monitor: DragGestureMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = Brand.appIcon(size: 512)
        MainActor.assumeIsolated {
            let menuBar = MenuBarController()
            menuBar.openSettings = { SettingsWindowController.shared.show() }
            menuBar.openWelcome = { WelcomeWindowController.shared.show(skipIntro: true) }
            self.menuBar = menuBar

            WheelController.shared.onAction = { action, urls in
                MainActor.assumeIsolated { ActionRouter.handle(action, urls: urls) }
            }
            let monitor = DragGestureMonitor(wheel: WheelController.shared)
            monitor.start()
            self.monitor = monitor

            if !AppSettings.shared.hasCompletedWelcome {
                WelcomeWindowController.shared.show(skipIntro: false)
            }
            DebugHooks.runIfRequested()
        }
    }

    /// Re-opening the app from Finder or Spotlight shows Settings, like other menu bar apps.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { SettingsWindowController.shared.show() }
        return false
    }
}

/// Turns a wheel drop into work.
@MainActor
enum ActionRouter {
    static func handle(_ action: WheelItem.Action, urls: [URL]) {
        switch action {
        case .convert(let target):
            JobCenter.shared.enqueue(Job(
                title: "Converting to \(target.label)",
                items: urls,
                perItem: { url, context in try await ConversionEngine.convert(url, to: target, context: context) },
                successTitle: { outputs in outputs.count > 1 ? "Converted \(outputs.count) files to \(target.label)" : "Converted to \(target.label)" }
            ))
        case .tool(let tool):
            ToolCoordinator.shared.open(tool, urls: urls)
        }
    }
}

/// Development hooks driven by environment variables, used for screenshots and tests.
@MainActor
enum DebugHooks {
    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        if let files = environment["CLEMENTINE_DEMO_WHEEL"] {
            let urls = files.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            let mode: WheelMode = environment["CLEMENTINE_DEMO_MODE"] == "tools" ? .tools : .convert
            if let style = environment["CLEMENTINE_DEMO_STYLE"].flatMap(WheelStyle.init(rawValue:)) {
                AppSettings.shared.wheelStyle = style
            }
            let screen = NSScreen.main?.frame ?? .zero
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WheelController.shared.present(mode: mode, urls: urls, at: NSPoint(x: screen.midX, y: screen.midY))
                if let hover = environment["CLEMENTINE_DEMO_HOVER"].flatMap(Int.init) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        WheelController.shared.updateHover(.petal(hover))
                    }
                }
            }
        }
        if let tab = environment["CLEMENTINE_DEMO_SETTINGS"] {
            SettingsWindowController.shared.show(tab: SettingsTab(rawValue: tab))
        }
        // CLEMENTINE_OPEN_TOOL="trimVideo|/path/a.mov|/path/b.mov" opens that editor at launch.
        if let spec = environment["CLEMENTINE_OPEN_TOOL"] {
            let parts = spec.split(separator: "|").map(String.init)
            if let tool = parts.first.flatMap(FileTool.init(rawValue:)) {
                let urls = parts.dropFirst().map { URL(fileURLWithPath: $0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { ToolCoordinator.shared.open(tool, urls: Array(urls)) }
            }
        }
        if environment["CLEMENTINE_OPEN_WELCOME"] != nil {
            WelcomeWindowController.shared.show(skipIntro: environment["CLEMENTINE_OPEN_WELCOME"] == "tour")
        }
    }
}
