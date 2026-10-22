import SwiftUI

extension SnapshotRegistry {
    /// Named views that `--snapshot` can render.
    static func registerAll() {
        guard builders.isEmpty else { return }
        let settingsSize = CGSize(width: 456, height: 560)
        for tab in SettingsTab.allCases {
            builders["settings-\(tab.rawValue)"] = { _, _ in
                let navigation = SettingsNavigation()
                navigation.tab = tab
                return Entry(view: AnyView(SettingsView(navigation: navigation)), size: settingsSize)
            }
        }
        builders["hud"] = { files, _ in
            Entry(view: AnyView(JobHUDPreview(fileName: files.first?.lastPathComponent ?? "photo.jpg")), size: CGSize(width: 380, height: 150))
        }
        for tool in FileTool.allCases {
            builders["tool-\(tool.rawValue)"] = { files, _ in
                let session = ToolSession(tool: tool, urls: files)
                let group = ToolCoordinator.groups.first { $0.tools.contains(tool) }
                guard let editor = group?.makeEditor(for: session) else {
                    return Entry(view: AnyView(ToolMessageView(symbol: "hammer", message: "No editor")), size: CGSize(width: 300, height: 200))
                }
                return Entry(view: AnyView(editor.view.environmentObject(session)), size: editor.size)
            }
        }
        for group in ToolCoordinator.groups { group.registerSnapshots() }
    }
}

/// Static HUD state for snapshots.
struct JobHUDPreview: View {
    var fileName: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                Text("Converting to PNG").font(.system(size: 15, weight: .bold))
                Spacer()
            }
            Text("\(fileName) · 1 of 3").font(.system(size: 13))
            OrangeProgressBar(fraction: 0.42)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(white: 0.5)))
        .padding(10)
    }
}
