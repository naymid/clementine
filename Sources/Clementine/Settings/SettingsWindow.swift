import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    let navigation = SettingsNavigation()

    func show(tab: SettingsTab? = nil) {
        if let tab { navigation.tab = tab }
        let window = self.window ?? makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(navigation: navigation))
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(Brand.appName) Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 456, height: 560))
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, formats, compatibility, folders, about
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettingsView().tabItem { Text("General") }.tag(SettingsTab.general)
            FormatsSettingsView().tabItem { Text("Formats") }.tag(SettingsTab.formats)
            CompatibilitySettingsView().tabItem { Text("Compatibility") }.tag(SettingsTab.compatibility)
            FoldersSettingsView().tabItem { Text("Folders") }.tag(SettingsTab.folders)
            AboutSettingsView().tabItem { Text("About") }.tag(SettingsTab.about)
        }
        .tint(Brand.buttonOrange)
        .padding(.top, 2)
        .frame(width: 456, height: 560)
    }
}

// MARK: - General

/// Wraps SMAppService so the toggle reflects the real login item state.
final class LoginItemModel: ObservableObject {
    @Published var isEnabled = false
    @Published var needsApproval = false
    @Published var error: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Couldn’t update launch at login. You can try again, or set it up later in System Settings."
        }
        refresh()
    }
}

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var loginItem = LoginItemModel()

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Style", selection: $settings.wheelStyle) {
                    ForEach(WheelStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                    .toggleStyle(.checkbox)
                if loginItem.needsApproval {
                    HStack {
                        Text("One more step: allow \(Brand.appName) in macOS Login Items.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = loginItem.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                Toggle("Sound and haptic feedback", isOn: $settings.soundsAndHaptics)
                    .toggleStyle(.checkbox)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Drag Modifiers").font(.system(size: 13, weight: .semibold))
                    modifierPicker("Conversion wheel", selection: $settings.conversionModifier, excluding: settings.toolsModifier)
                    modifierPicker("Tools wheel", selection: $settings.toolsModifier, excluding: settings.conversionModifier)
                    Text("Hold the chosen modifier combination while dragging files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }

    private func modifierPicker(_ title: String, selection: Binding<ModifierCombo>, excluding other: ModifierCombo) -> some View {
        Picker(title, selection: selection) {
            ForEach(ModifierCombo.all.filter { $0 != other }) { combo in
                Text(combo.menuTitle).tag(combo)
            }
        }
    }
}

// MARK: - Folders

struct FoldersSettingsView: View {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    var body: some View {
        Form {
            Section("Folder Access") {
                Text("\(Brand.appName) saves results beside the originals. It isn’t sandboxed, so there is no folder list to manage. macOS asks once, the first time it saves into Desktop, Documents or Downloads; click Allow and it won’t ask again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: home.path))
                        .resizable()
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(home.lastPathComponent).font(.system(size: 13, weight: .semibold))
                        Text(home.path).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Brand.buttonOrange)
                        .help("Full access")
                }
                .padding(.vertical, 2)
                HStack {
                    Spacer()
                    Button("Show Home Folder") { NSWorkspace.shared.open(home) }
                        .buttonStyle(TintedButtonStyle())
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            AppIconView(size: 128)
            Text(Brand.appName)
                .font(.system(size: 17, weight: .bold))
                .padding(.top, 4)
            Text("Version \(Brand.version) (\(Brand.build))")
                .foregroundStyle(.secondary)
            Text(settings.conversionCount == 1 ? "1 job done. Unlimited, no free-use limit." : "\(settings.conversionCount) jobs done. Unlimited, no free-use limit.")
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            HStack(spacing: 12) {
                Button("Getting Started…") { WelcomeWindowController.shared.show(skipIntro: true) }
                    .buttonStyle(FilledOrangeButtonStyle())
                Button("Format Compatibility") { SettingsWindowController.shared.navigation.tab = .compatibility }
                    .buttonStyle(TintedButtonStyle())
            }
            Text("\(FormatCompatibility.totalConversions) conversions · \(FileTool.allCases.count) tools · all on this Mac")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shared button styles

/// Solid orange capsule-ish button (Unlock…, Next).
struct FilledOrangeButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 7
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Brand.buttonOrange.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}

/// Orange text on a faint orange plate (Restore Defaults, Add Folder…).
struct TintedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Brand.buttonOrange)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Brand.buttonOrange.opacity(configuration.isPressed ? 0.22 : 0.12)))
    }
}
