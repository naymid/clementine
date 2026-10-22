import AppKit
import SwiftUI

/// The floating progress panel in the top-right corner.
@MainActor
final class JobHUDController {
    private unowned let center: JobCenter
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    init(center: JobCenter) {
        self.center = center
    }

    func show() {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        position(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.center.isWorking else { return }
                self.hide()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 14, y: visible.maxY - size.height - 10))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hosting = NSHostingView(rootView: JobHUDView(center: center))
        hosting.sizingOptions = []
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = hosting
        self.panel = panel
        return panel
    }
}

struct JobHUDView: View {
    @ObservedObject var center: JobCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    center.dismissHUD()
                } label: {
                    Image(systemName: center.phase == .finished ? "checkmark" : "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                        .foregroundStyle(center.phase == .finished ? Brand.accent : Color.primary.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help(center.phase == .running ? "Cancel" : "Close")
                Text(center.title)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if center.phase == .failed {
                ScrollView {
                    Text(center.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 54)
            } else {
                Text(center.detail)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if center.phase == .finished, !center.outputs.isEmpty {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(center.outputs) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.accent)
            } else if center.phase == .running {
                OrangeProgressBar(fraction: center.fraction)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 360, alignment: .leading)
        .background(HUDBackground())
        .padding(10)
        .frame(width: 380, height: 150, alignment: .top)
    }
}

/// Rounded HUD plate: Liquid Glass on macOS 26, a blurred material before that.
struct HUDBackground: View {
    var cornerRadius: CGFloat = 24

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *), AppSettings.shared.wheelStyle == .glass {
            shape.fill(Color.clear).glassEffect(.regular, in: shape)
        } else {
            VisualEffectBlur(material: .hudWindow)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        }
    }
}

/// The orange progress bar. With no fraction it sweeps like the original's indeterminate bar.
struct OrangeProgressBar: View {
    var fraction: Double?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.18))
                if let fraction {
                    Capsule()
                        .fill(Brand.accent)
                        .frame(width: max(height, proxy.size.width * fraction))
                        .animation(.easeOut(duration: 0.2), value: fraction)
                } else {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let phase = (t.truncatingRemainder(dividingBy: 1.4)) / 1.4
                        let width = proxy.size.width * 0.28
                        Capsule()
                            .fill(Brand.accent)
                            .frame(width: width)
                            .offset(x: -width + (proxy.size.width + width) * phase)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: height)
    }
}
