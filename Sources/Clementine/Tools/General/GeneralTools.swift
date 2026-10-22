import SwiftUI

/// Editors for this group's tools. Placeholder until the editors are built.
@MainActor
enum GeneralTools: ToolGroup {
    static let tools: Set<FileTool> = [.compress, .removeMetadata, .splitPDF, .organizePDF, .mergePDF, .createPDF, .readQRCode, .extractArchive]

    static func makeEditor(for session: ToolSession) -> ToolEditor? {
        nil
    }

    static func runImmediately(_ session: ToolSession) {
        ToolCoordinator.shared.showUnavailable(session)
    }

    static func registerSnapshots() {}
}
