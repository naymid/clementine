import SwiftUI

/// Editors for this group's tools. Placeholder until the editors are built.
@MainActor
enum VideoTools: ToolGroup {
    static let tools: Set<FileTool> = [.trimVideo, .cropVideo, .changeVideoSpeed, .splitVideo, .videoSnapshots, .redactVideo, .joinVideos, .muteVideo]

    static func makeEditor(for session: ToolSession) -> ToolEditor? {
        nil
    }

    static func runImmediately(_ session: ToolSession) {
        ToolCoordinator.shared.showUnavailable(session)
    }

    static func registerSnapshots() {}
}
