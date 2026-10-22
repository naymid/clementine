import AppKit
import Combine

/// A unit of work shown in the HUD: either per-file or one batch over all files.
struct Job {
    var title: String
    var items: [URL]
    var perItem: ((URL, JobContext) async throws -> [URL])?
    var batch: (([URL], JobContext) async throws -> [URL])?
    var successTitle: ((_ outputs: [URL]) -> String)?
    var revealOutputs = true
    var onFinish: ((_ outputs: [URL], _ failures: [String]) -> Void)?
}

/// Runs jobs one at a time and publishes progress for the HUD.
@MainActor
final class JobCenter: ObservableObject {
    static let shared = JobCenter()

    enum Phase: Equatable { case idle, running, finished, failed }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var title = ""
    @Published private(set) var detail = ""
    @Published private(set) var fraction: Double?
    @Published private(set) var failures: [String] = []
    @Published private(set) var outputs: [URL] = []

    private var queue: [Job] = []
    private var currentContext: JobContext?
    private var isRunning = false
    private var cancelRequested = false
    lazy var hud = JobHUDController(center: self)

    var isWorking: Bool { isRunning }

    func enqueue(_ job: Job) {
        queue.append(job)
        if !isRunning { runNext() }
    }

    func cancelCurrent() {
        cancelRequested = true
        currentContext?.cancel()
        queue.removeAll()
    }

    func dismissHUD() {
        if isRunning { cancelCurrent() }
        hud.hide()
        if !isRunning { phase = .idle }
    }

    private func runNext() {
        guard !queue.isEmpty else { return }
        let job = queue.removeFirst()
        isRunning = true
        cancelRequested = false
        phase = .running
        title = job.title
        failures = []
        outputs = []
        fraction = nil
        hud.show()
        Task { await run(job) }
    }

    private func run(_ job: Job) async {
        var produced: [URL] = []
        var errors: [String] = []
        let total = job.items.count
        if let batch = job.batch {
            detail = total == 1 ? job.items[0].lastPathComponent : "\(total) files"
            let context = makeContext(index: 0, total: 1)
            do { produced = try await batch(job.items, context) } catch { if !isCancel(error) { errors.append(error.localizedDescription) } }
        } else if let perItem = job.perItem {
            for (index, url) in job.items.enumerated() {
                if cancelRequested { break }
                detail = total > 1 ? "\(url.lastPathComponent) · \(index + 1) of \(total)" : url.lastPathComponent
                let context = makeContext(index: index, total: total)
                do {
                    produced += try await perItem(url, context)
                } catch {
                    if isCancel(error) { break }
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        currentContext = nil
        outputs = produced
        failures = errors
        isRunning = false
        if cancelRequested {
            phase = .idle
            hud.hide()
        } else if errors.isEmpty {
            AppSettings.shared.conversionCount += 1
            phase = .finished
            title = job.successTitle?(produced) ?? Self.defaultSuccessTitle(produced)
            detail = produced.count == 1 ? produced[0].lastPathComponent : "Saved beside the originals"
            fraction = 1
            Feedback.finished(success: true)
            if job.revealOutputs { Self.reveal(produced) }
            hud.scheduleHide(after: 2.6)
        } else {
            phase = .failed
            title = produced.isEmpty ? "Conversion failed" : "Finished with errors"
            detail = errors.joined(separator: "\n")
            Feedback.finished(success: false)
        }
        job.onFinish?(produced, errors)
        if !queue.isEmpty { runNext() }
    }

    private func makeContext(index: Int, total: Int) -> JobContext {
        let context = JobContext { [weak self] value in
            DispatchQueue.main.async {
                guard let self else { return }
                self.fraction = (Double(index) + value) / Double(max(total, 1))
            }
        }
        currentContext = context
        return context
    }

    private func isCancel(_ error: Error) -> Bool {
        if case ProcessError.cancelled = error { return true }
        return cancelRequested
    }

    static func defaultSuccessTitle(_ outputs: [URL]) -> String {
        outputs.count == 1 ? "Saved" : "Saved \(outputs.count) files"
    }

    /// Selects new files in Finder, unless they landed on the Desktop where they are already visible.
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.standardizedFileURL
        if urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == desktop }) { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
