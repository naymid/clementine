import AppKit
import Combine

/// The status item and its menu.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    var openSettings: () -> Void = {}
    var openWelcome: () -> Void = {}

    override init() {
        super.init()
        if let button = statusItem.button {
            button.image = Brand.menuBarImage()
            button.setAccessibilityLabel("\(Brand.appName) conversions")
            button.toolTip = Brand.appName
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuild()
        JobCenter.shared.$phase.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }.store(in: &cancellables)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func updateIcon() {
        statusItem.button?.appearsDisabled = false
        statusItem.button?.alphaValue = JobCenter.shared.isWorking ? 0.6 : 1
    }

    private func rebuild() {
        menu.removeAllItems()
        let working = JobCenter.shared.isWorking
        let status = NSMenuItem(title: working ? "\(Brand.appName) is working" : "\(Brand.appName) is ready", action: nil, keyEquivalent: "")
        status.image = NSImage(systemSymbolName: working ? "arrow.triangle.2.circlepath" : "checkmark.circle", accessibilityDescription: nil)
        status.isEnabled = false
        menu.addItem(status)

        let hint = NSMenuItem(title: AppSettings.shared.gestureHint, action: nil, keyEquivalent: "")
        hint.isEnabled = false
        hint.indentationLevel = 1
        menu.addItem(hint)

        menu.addItem(.separator())
        menu.addItem(item("Settings…", symbol: "gearshape", key: ",", action: #selector(settingsAction)))
        menu.addItem(item("Getting Started…", symbol: "sparkle", key: "", action: #selector(welcomeAction)))
        let about = item("About \(Brand.appName)", symbol: nil, key: "", action: #selector(aboutAction))
        about.indentationLevel = 0
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(item("Quit \(Brand.appName)", symbol: nil, key: "q", action: #selector(quitAction)))
    }

    private func item(_ title: String, symbol: String?, key: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    @objc private func settingsAction() { openSettings() }
    @objc private func welcomeAction() { openWelcome() }

    @objc private func aboutAction() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: Brand.appName,
            .applicationIcon: Brand.appIcon(size: 256),
            .applicationVersion: Brand.version,
            .version: Brand.build,
            .credits: NSAttributedString(string: "Hold. Drag. Drop.\nConverts and edits files right where they are.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc private func quitAction() { NSApp.terminate(nil) }
}
