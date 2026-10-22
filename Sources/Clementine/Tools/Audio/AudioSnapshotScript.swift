import AppKit
import SwiftUI

/// Replays mouse and key events into the snapshot window so editor interactions can be
/// checked headlessly: `--snapshot audio-scripted out.png --tool redactAudio --files … --script "wait:2;drag:100,200,300,200;key:delete"`.
/// Points are in window coordinates with the origin at the top left.
struct AudioSnapshotScript: NSViewRepresentable {
    enum Step {
        case wait(Double)
        case drag(CGPoint, CGPoint)
        case click(CGPoint)
        case key(String)
    }

    var steps: [Step]

    static func parse(_ text: String) -> [Step] {
        text.split(separator: ";").compactMap { part in
            let pieces = part.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2 else { return nil }
            let numbers = pieces[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            switch pieces[0] {
            case "wait": return numbers.first.map { .wait($0) }
            case "drag" where numbers.count == 4:
                return .drag(CGPoint(x: numbers[0], y: numbers[1]), CGPoint(x: numbers[2], y: numbers[3]))
            case "click" where numbers.count == 2: return .click(CGPoint(x: numbers[0], y: numbers[1]))
            case "key": return .key(pieces[1])
            default: return nil
            }
        }
    }

    final class Runner: NSView {
        var steps: [Step] = []
        private var started = false
        private var eventNumber = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !started else { return }
            started = true
            // Note: this window is borderless and never key. SwiftUI then treats a click as a
            // window-activating click (and skips drag gestures) when the view tree contains a
            // text field; AudioMouseSurface accepts first mouse to work in that case too.
            var delay = 0.0
            for step in steps {
                switch step {
                case .wait(let seconds):
                    delay += seconds
                case .click(let point):
                    schedule(after: delay) { self.mouse(.leftMouseDown, point, window) }
                    delay += 0.05
                    schedule(after: delay) { self.mouse(.leftMouseUp, point, window) }
                    delay += 0.15
                case .drag(let from, let to):
                    schedule(after: delay) { self.mouse(.leftMouseDown, from, window) }
                    let count = 12
                    for index in 1...count {
                        delay += 0.03
                        let fraction = CGFloat(index) / CGFloat(count)
                        let point = CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
                        schedule(after: delay) { self.mouse(.leftMouseDragged, point, window) }
                    }
                    delay += 0.05
                    schedule(after: delay) { self.mouse(.leftMouseUp, to, window) }
                    delay += 0.2
                case .key(let name):
                    schedule(after: delay) { self.key(name, window) }
                    delay += 0.2
                }
            }
        }

        private func schedule(after delay: Double, _ work: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, _ window: NSWindow) {
            eventNumber += 1
            let height = window.contentView?.bounds.height ?? window.frame.height
            guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: height - point.y), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: eventNumber, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { return }
            window.sendEvent(event)
        }

        private func key(_ name: String, _ window: NSWindow) {
            let (characters, code): (String, UInt16) = {
                switch name {
                case "delete": return ("\u{7F}", 51)
                case "space": return (" ", 49)
                case "backspace": return ("\u{8}", 51)
                default: return (name, 0)
                }
            }()
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: code) else { return }
            if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        }
    }

    /// A bare toolkit RangeTrack with its values printed, to check track interaction in isolation.
    /// (It shows that dragging RangeTrack's start grip moves `end`: its grips set `.contentShape`
    /// after `.offset`, so both hit areas sit at the leading edge. Trim Audio uses AudioTrimTrack.)
    struct RangeTrackProbe: View {
        @State private var start = 0.0
        @State private var end = 6.5
        @State private var playhead = 0.0
        var withField = false

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                RangeTrack(start: $start, end: $end, duration: 6.5, playhead: playhead, onScrub: { playhead = $0 }) {
                    Color.gray.opacity(0.3)
                }
                .frame(height: 100)
                Text("start \(AudioFFmpeg.number(start, digits: 2))  end \(AudioFFmpeg.number(end, digits: 2))  playhead \(AudioFFmpeg.number(playhead, digits: 2))")
                    .font(.system(size: 16).monospacedDigit())
                if withField {
                    SecondsField(title: "Start", seconds: $start, range: 0...6.5)
                }
            }
            .padding(20)
            .onChange(of: start) { _, value in print("probe: start \(value)") }
            .onChange(of: end) { _, value in print("probe: end \(value)") }
            .onChange(of: playhead) { _, value in print("probe: playhead \(value)") }
        }
    }

    func makeNSView(context: Context) -> Runner {
        let view = Runner()
        view.steps = steps
        return view
    }

    func updateNSView(_ nsView: Runner, context: Context) {}
}
