import AppKit

/// Watches for file drags anywhere on screen and opens the wheel when the
/// configured modifiers are held. Uses polling so it needs no Accessibility
/// permission: the drag pasteboard changes when a drag starts, and the mouse
/// button and modifier state are readable globally.
@MainActor
final class DragGestureMonitor {
    private let wheel: WheelController
    private let settings = AppSettings.shared
    private var idleTimer: Timer?
    private var trackingTimer: Timer?
    private var wasButtonDown = false
    private var changeCountAtPress = 0
    private var dragURLs: [URL] = []
    private var isTracking = false
    private var activeMode: WheelMode?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(wheel: WheelController) {
        self.wheel = wheel
    }

    func start() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.idleTick() } }
        RunLoop.main.add(idleTimer!, forMode: .common)
        // Event monitors make detection instant when they are delivered; polling covers the rest.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            noteButtonDown()
        } else if !isTracking {
            beginTrackingIfFileDrag()
        }
    }

    private func noteButtonDown() {
        wasButtonDown = true
        changeCountAtPress = NSPasteboard(name: .drag).changeCount
    }

    private func idleTick() {
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        if buttonDown && !wasButtonDown {
            noteButtonDown()
        } else if !buttonDown {
            wasButtonDown = false
        }
        if buttonDown && !isTracking { beginTrackingIfFileDrag() }
    }

    private func beginTrackingIfFileDrag() {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != changeCountAtPress else { return }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        // Remember this pasteboard state so a non-file drag is not re-examined every tick.
        changeCountAtPress = pasteboard.changeCount
        guard !urls.isEmpty else { return }
        dragURLs = urls
        isTracking = true
        activeMode = nil
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.trackingTick() } }
        RunLoop.main.add(trackingTimer!, forMode: .common)
        trackingTick()
    }

    private func trackingTick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            endTracking()
            return
        }
        let combo = ModifierCombo(flags: NSEvent.modifierFlags)
        var wanted: WheelMode?
        if combo == settings.conversionModifier { wanted = .convert }
        if combo == settings.toolsModifier { wanted = .tools }
        guard let mode = wanted, mode != activeMode else { return }
        if activeMode == nil || !wheel.isVisible {
            wheel.present(mode: mode, urls: dragURLs, at: NSEvent.mouseLocation)
            Feedback.highlight()
        } else {
            wheel.switchMode(mode)
        }
        activeMode = mode
    }

    private func endTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        isTracking = false
        activeMode = nil
        wasButtonDown = false
        // Give a drop on the wheel a moment to be delivered before hiding it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.isTracking else { return }
            self.wheel.dismiss()
        }
    }
}
