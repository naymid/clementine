import SwiftUI

/// Editors for this group's tools. Placeholder until the editors are built.
@MainActor
enum AudioTools: ToolGroup {
    static let tools: Set<FileTool> = [.trimAudio, .normalizeAudio, .audioChannels, .audioToVideo, .redactAudio]

    static func makeEditor(for session: ToolSession) -> ToolEditor? {
        nil
    }

    static func runImmediately(_ session: ToolSession) {
        ToolCoordinator.shared.showUnavailable(session)
    }

    static func registerSnapshots() {}
}
