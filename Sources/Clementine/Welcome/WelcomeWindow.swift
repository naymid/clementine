import AppKit
import SwiftUI

/// The first-run splash and the four-page Getting Started tour.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    let model = WelcomeModel()
    private var tourWindow: NSWindow?
    private var splashWindow: NSWindow?

    func show(skipIntro: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        if skipIntro {
            showTour()
        } else {
            showSplash()
        }
    }

    // MARK: Splash

    private func showSplash() {
        let size = NSSize(width: 640, height: 420)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WelcomeSplashView(
            onContinue: { [weak self] in
                self?.splashWindow?.orderOut(nil)
                self?.splashWindow = nil
                self?.showTour()
            },
            onClose: { [weak self] in
                self?.splashWindow?.orderOut(nil)
                self?.splashWindow = nil
            }))
        window.center()
        splashWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Tour

    private func showTour() {
        model.page = .holdDragDrop
        model.resetPractice()
        let window = tourWindow ?? makeTourWindow()
        WheelController.shared.practiceInterceptor = { [weak self] action, urls in
            MainActor.assumeIsolated { self?.model.handlePracticeDrop(action: action, urls: urls) ?? false }
        }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeTourWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 570),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to \(Brand.appName)"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: WelcomeTourView(model: model, onFinish: { [weak self] in
            AppSettings.shared.hasCompletedWelcome = true
            self?.tourWindow?.close()
        }))
        tourWindow = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        WheelController.shared.practiceInterceptor = nil
        if (notification.object as? NSWindow) === tourWindow {
            AppSettings.shared.hasCompletedWelcome = true
        }
    }
}

enum WelcomePage: Int, CaseIterable {
    case holdDragDrop, tools, saveBeside, ready
}

/// Drives the tour: page, practice files, and the "Show me" demonstration.
@MainActor
final class WelcomeModel: ObservableObject {
    enum PracticeState: Equatable {
        case idle
        case demoHolding        // keycaps shown, file lifting
        case demoWheel          // wheel open, file over a petal
        case done(String)       // file name of the new copy
    }

    @Published var page: WelcomePage = .holdDragDrop
    @Published var practice: PracticeState = .idle
    @Published var demoFileOffset: CGSize = .zero
    @Published var demoFileLifted = false
    let demoWheel = WheelModel()

    private var demoTask: Task<Void, Never>?

    lazy var photoURL: URL = PracticeFiles.photo()
    lazy var videoURL: URL = PracticeFiles.video()

    var isToolsPage: Bool { page == .tools }
    var practiceURL: URL { isToolsPage ? videoURL : photoURL }

    func go(to page: WelcomePage) {
        demoTask?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) { self.page = page }
        resetPractice()
    }

    func resetPractice() {
        demoTask?.cancel()
        practice = .idle
        demoFileOffset = .zero
        demoFileLifted = false
        demoWheel.isPresented = false
        demoWheel.hovered = nil
    }

    var statusText: String {
        switch practice {
        case .idle: return "A practice file. Nothing on your Mac changes."
        case .demoHolding: return isToolsPage ? "Keep dragging and hold Option + Shift." : "Keep dragging and hold Shift."
        case .demoWheel: return isToolsPage ? "Let go to use compress." : "Let go to make a PNG copy."
        case .done: return isToolsPage ? "Done — the original and smaller copy are both here." : "Done — the original and new file are both here."
        }
    }

    /// Real drags of the practice file onto the real wheel land here instead of converting.
    func handlePracticeDrop(action: WheelItem.Action, urls: [URL]) -> Bool {
        guard urls.contains(where: { $0.standardizedFileURL == photoURL.standardizedFileURL || $0.standardizedFileURL == videoURL.standardizedFileURL }) else {
            return false
        }
        let base = FileNaming.baseName(of: practiceURL)
        let name: String
        switch action {
        case .convert(let format): name = "\(base).\(format.outputExtension)"
        case .tool(let tool):
            name = tool == .compress ? "\(base)-smaller.\(practiceURL.pathExtension)" : "\(base)-\(tool.petalLabel.lowercased()).\(practiceURL.pathExtension)"
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { practice = .done(name) }
        Feedback.finished(success: true)
        return true
    }

    /// Animated demonstration of the gesture inside the tour window.
    func showMe() {
        resetPractice()
        let tools = isToolsPage
        configureDemoWheel(tools: tools)
        demoTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.3)) {
                practice = .demoHolding
                demoFileLifted = true
            }
            withAnimation(.easeInOut(duration: 0.9)) { demoFileOffset = CGSize(width: 90, height: -20) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            practice = .demoWheel
            demoWheel.isPresented = true
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            // Glide the file up onto the top petal.
            withAnimation(.easeInOut(duration: 0.7)) { demoFileOffset = CGSize(width: 268, height: -112) }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            demoWheel.hovered = 0
            Feedback.highlight()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            demoWheel.isPresented = false
            demoWheel.hovered = nil
            let base = FileNaming.baseName(of: practiceURL)
            let name = tools ? "\(base)-smaller.\(practiceURL.pathExtension)" : "\(base).png"
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                demoFileLifted = false
                demoFileOffset = .zero
                practice = .done(name)
            }
        }
    }

    private func configureDemoWheel(tools: Bool) {
        demoWheel.style = AppSettings.shared.wheelStyle
        demoWheel.emptyMessage = nil
        if tools {
            demoWheel.mode = .tools
            demoWheel.items = FileTool.tools(for: [.mp4]).map(WheelItem.tool)
        } else {
            demoWheel.mode = .convert
            demoWheel.items = FormatCompatibility.targets(for: .jpg).map(WheelItem.format)
        }
        demoWheel.summaryTitle = ""
        demoWheel.summarySize = FileNaming.formattedSize(FileNaming.size(of: practiceURL))
    }
}

/// Generates the practice files once, in Application Support.
enum PracticeFiles {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clementine/Practice", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func photo() -> URL {
        let url = directory.appendingPathComponent("landscape.jpg")
        if !FileManager.default.fileExists(atPath: url.path), let image = PracticeArt.landscape(size: CGSize(width: 1600, height: 1200)),
           let data = ImageIOHelpers.jpegData(image, quality: 0.9) {
            try? data.write(to: url)
        }
        return url
    }

    static func video() -> URL {
        let url = directory.appendingPathComponent("coast-ride.mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            if let ffmpeg = ToolPaths.ffmpeg {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.arguments = ["-y", "-v", "error", "-f", "lavfi", "-i", "gradients=s=960x540:d=4:speed=0.02:c0=0xff8a00:c1=0x2a6fdb",
                                     "-c:v", "libx264", "-pix_fmt", "yuv420p", "-t", "4", url.path]
                try? process.run()
                process.waitUntilExit()
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data(count: 1024))
            }
        }
        return url
    }

    static func thumbnail(for url: URL) -> NSImage {
        if url.pathExtension == "mp4" {
            return NSImage(cgImage: PracticeArt.coast(size: CGSize(width: 320, height: 180))!, size: NSSize(width: 320, height: 180))
        }
        return NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Procedural practice artwork, so no stock photos ship with the app.
enum PracticeArt {
    static func landscape(size: CGSize) -> CGImage? {
        draw(size: size) { context in
            let w = size.width, h = size.height
            let sky = CGGradient(colorsSpace: nil, colors: [
                CGColor(srgbRed: 1.0, green: 0.78, blue: 0.48, alpha: 1),
                CGColor(srgbRed: 0.46, green: 0.70, blue: 0.95, alpha: 1),
            ] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h * 0.35), end: CGPoint(x: 0, y: h), options: [])
            context.setFillColor(CGColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1))
            context.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.55, width: w * 0.16, height: w * 0.16))
            func hill(_ color: CGColor, base: CGFloat, amplitude: CGFloat, phase: CGFloat) {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: base))
                for x in stride(from: 0, through: w, by: 8) {
                    path.addLine(to: CGPoint(x: x, y: base + sin(x / w * .pi * 2.2 + phase) * amplitude))
                }
                path.addLine(to: CGPoint(x: w, y: 0))
                path.closeSubpath()
                context.addPath(path)
                context.setFillColor(color)
                context.fillPath()
            }
            hill(CGColor(srgbRed: 0.33, green: 0.55, blue: 0.36, alpha: 1), base: h * 0.42, amplitude: h * 0.06, phase: 0.6)
            hill(CGColor(srgbRed: 0.20, green: 0.42, blue: 0.27, alpha: 1), base: h * 0.30, amplitude: h * 0.05, phase: 2.0)
            // A row of clementine trees.
            for index in 0..<5 {
                let x = w * (0.1 + CGFloat(index) * 0.2)
                context.setFillColor(CGColor(srgbRed: 0.36, green: 0.24, blue: 0.14, alpha: 1))
                context.fill(CGRect(x: x - 6, y: h * 0.18, width: 12, height: h * 0.1))
                context.setFillColor(CGColor(srgbRed: 0.18, green: 0.48, blue: 0.22, alpha: 1))
                context.fillEllipse(in: CGRect(x: x - w * 0.07, y: h * 0.24, width: w * 0.14, height: w * 0.11))
                context.setFillColor(CGColor(srgbRed: 1.0, green: 0.55, blue: 0.10, alpha: 1))
                for fruit in 0..<6 {
                    let fx = x - w * 0.045 + CGFloat(fruit % 3) * w * 0.035
                    let fy = h * 0.28 + CGFloat(fruit / 3) * w * 0.035
                    context.fillEllipse(in: CGRect(x: fx, y: fy, width: w * 0.022, height: w * 0.022))
                }
            }
        }
    }

    static func coast(size: CGSize) -> CGImage? {
        draw(size: size) { context in
            let w = size.width, h = size.height
            let sky = CGGradient(colorsSpace: nil, colors: [
                CGColor(srgbRed: 0.98, green: 0.55, blue: 0.25, alpha: 1),
                CGColor(srgbRed: 0.98, green: 0.82, blue: 0.55, alpha: 1),
            ] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h * 0.4), end: CGPoint(x: 0, y: h), options: [])
            context.setFillColor(CGColor(srgbRed: 0.18, green: 0.38, blue: 0.62, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.42))
            context.setFillColor(CGColor(srgbRed: 0.35, green: 0.25, blue: 0.2, alpha: 1))
            let cliff = CGMutablePath()
            cliff.move(to: CGPoint(x: w * 0.55, y: 0))
            cliff.addLine(to: CGPoint(x: w * 0.7, y: h * 0.62))
            cliff.addLine(to: CGPoint(x: w, y: h * 0.7))
            cliff.addLine(to: CGPoint(x: w, y: 0))
            cliff.closeSubpath()
            context.addPath(cliff)
            context.fillPath()
        }
    }

    private static func draw(size: CGSize, _ body: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        body(context)
        return context.makeImage()
    }
}
