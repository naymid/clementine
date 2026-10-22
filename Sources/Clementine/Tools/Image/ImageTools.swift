import SwiftUI

/// Editors for this group's tools. Placeholder until the editors are built.
@MainActor
enum ImageTools: ToolGroup {
    static let tools: Set<FileTool> = [.editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .createCollage]

    static func makeEditor(for session: ToolSession) -> ToolEditor? {
        nil
    }

    static func runImmediately(_ session: ToolSession) {
        ToolCoordinator.shared.showUnavailable(session)
    }

    static func registerSnapshots() {}
}
