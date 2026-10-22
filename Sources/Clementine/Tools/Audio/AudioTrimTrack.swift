import AppKit
import SwiftUI

/// Waveform with a draggable selection (orange frame with grips), a playhead and click-to-scrub,
/// styled like the toolkit's RangeTrack. Mouse handling is done by an AppKit surface that accepts
/// the first click, so the track responds even when the window is not yet key and while the
/// Start/End fields hold focus; each grip is grabbed exactly where it is drawn.
struct AudioTrimTrack: View {
    @Binding var start: Double
    @Binding var end: Double
    var duration: Double
    var playhead: Double?
    var samples: [Float]
    var minimumLength: Double = 0.05
    var onScrub: (Double) -> Void = { _ in }

    private enum Drag {
        case scrub
        case leading(offset: CGFloat)
        case trailing(offset: CGFloat)
    }

    @State private var drag: Drag?

    private let handle: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let usable = max(1, proxy.size.width - handle * 2)
            let length = max(duration, 0.001)
            let x = { (time: Double) -> CGFloat in handle + CGFloat(min(1, max(0, time / length))) * usable }
            let time = { (position: CGFloat) -> Double in Double(min(1, max(0, (position - handle) / usable))) * length }
            ZStack(alignment: .topLeading) {
                ZStack {
                    Color.primary.opacity(0.07)
                    WaveformView(samples: samples, color: Color.primary.opacity(0.55))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 2)
                }
                .frame(width: usable, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .offset(x: handle)
                // Dim what will be cut.
                Rectangle().fill(Color.black.opacity(0.45))
                    .frame(width: max(0, x(start) - handle), height: height)
                    .offset(x: handle)
                Rectangle().fill(Color.black.opacity(0.45))
                    .frame(width: max(0, x(length) - x(end)), height: height)
                    .offset(x: x(end))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Brand.buttonOrange, lineWidth: 3)
                    .frame(width: max(handle * 2, x(end) - x(start) + handle * 2), height: height)
                    .offset(x: x(start) - handle)
                grip(.leading, height: height)
                    .offset(x: x(start) - handle)
                    .accessibilityElement()
                    .accessibilityLabel("Trim start")
                    .accessibilityValue(AudioText.time(start))
                    .accessibilityAdjustableAction { direction in nudge(.leading, direction) }
                grip(.trailing, height: height)
                    .offset(x: x(end))
                    .accessibilityElement()
                    .accessibilityLabel("Trim end")
                    .accessibilityValue(AudioText.time(end))
                    .accessibilityAdjustableAction { direction in nudge(.trailing, direction) }
                if let playhead {
                    Capsule()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
                        .frame(width: 3, height: height + 8)
                        .offset(x: x(playhead) - 1.5, y: -4)
                }
            }
            // A fixed frame, so the mouse surface always covers the whole track.
            .frame(width: proxy.size.width, height: height, alignment: .topLeading)
            .overlay {
                let leftGrip = CGRect(x: x(start) - handle - 3, y: 0, width: handle + 6, height: height)
                let rightGrip = CGRect(x: x(end) - 3, y: 0, width: handle + 6, height: height)
                AudioMouseSurface(
                    toolTip: "Drag to scrub and play from a time",
                    resizeRects: [leftGrip, rightGrip],
                    onDown: { point in
                        if rightGrip.contains(point) && (!leftGrip.contains(point) || point.x >= x(end)) {
                            drag = .trailing(offset: x(end) - point.x)
                        } else if leftGrip.contains(point) {
                            drag = .leading(offset: x(start) - point.x)
                        } else {
                            drag = .scrub
                            onScrub(time(point.x))
                        }
                    },
                    onDrag: { point in
                        switch drag {
                        case .leading(let offset):
                            start = max(0, min(end - minimumLength, time(point.x + offset)))
                            onScrub(start)
                        case .trailing(let offset):
                            end = min(duration, max(start + minimumLength, time(point.x + offset)))
                            onScrub(end)
                        case .scrub:
                            onScrub(time(point.x))
                        case nil:
                            break
                        }
                    },
                    onUp: { _ in drag = nil })
            }
        }
    }

    private func grip(_ edge: HorizontalEdge, height: CGFloat) -> some View {
        UnevenRoundedRectangle(cornerRadii: edge == .leading
                               ? .init(topLeading: 6, bottomLeading: 6)
                               : .init(bottomTrailing: 6, topTrailing: 6), style: .continuous)
            .fill(Brand.buttonOrange)
            .overlay(Capsule().fill(Color.white.opacity(0.9)).frame(width: 2.5, height: height * 0.36))
            .frame(width: handle, height: height)
    }

    private func nudge(_ edge: HorizontalEdge, _ direction: AccessibilityAdjustmentDirection) {
        let step = direction == .increment ? 0.1 : -0.1
        if edge == .leading {
            start = max(0, min(end - minimumLength, start + step))
        } else {
            end = min(duration, max(start + minimumLength, end + step))
        }
    }
}

/// A transparent AppKit view that reports mouse down/drag/up in top-left coordinates,
/// accepts the first click in an inactive window, and shows the resize cursor over `resizeRects`.
struct AudioMouseSurface: NSViewRepresentable {
    var toolTip: String?
    var resizeRects: [CGRect] = []
    var onDown: (CGPoint) -> Void
    var onDrag: (CGPoint) -> Void
    var onUp: (CGPoint) -> Void

    final class SurfaceView: NSView {
        var onDown: (CGPoint) -> Void = { _ in }
        var onDrag: (CGPoint) -> Void = { _ in }
        var onUp: (CGPoint) -> Void = { _ in }
        var resizeRects: [CGRect] = [] {
            didSet { if resizeRects != oldValue { window?.invalidateCursorRects(for: self) } }
        }

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
        override func mouseDown(with event: NSEvent) { onDown(point(event)) }
        override func mouseDragged(with event: NSEvent) { onDrag(point(event)) }
        override func mouseUp(with event: NSEvent) { onUp(point(event)) }

        override func resetCursorRects() {
            for rect in resizeRects { addCursorRect(rect, cursor: .resizeLeftRight) }
        }
    }

    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        update(view)
        return view
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        update(view)
    }

    private func update(_ view: SurfaceView) {
        view.onDown = onDown
        view.onDrag = onDrag
        view.onUp = onUp
        view.resizeRects = resizeRects
        view.toolTip = toolTip
    }
}
