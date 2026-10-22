import Foundation

/// Per-job plumbing handed to converters: progress reporting and cancellation.
final class JobContext: @unchecked Sendable {
    let runner = ProcessRunner()
    private let progressHandler: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        progressHandler = progress
    }

    func progress(_ fraction: Double) {
        progressHandler(min(1, max(0, fraction)))
    }

    func cancel() { runner.cancel() }
    var isCancelled: Bool { runner.isCancelled }

    func checkCancelled() throws {
        if isCancelled { throw ProcessError.cancelled }
    }
}

enum ConversionError: LocalizedError {
    case unsupported(FileFormat?, FileFormat)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .unsupported(let source, let target):
            return "Conversion from \(source?.label ?? "this file") to \(target.label) is unavailable."
        case .noOutput:
            return "The converter finished without creating an output file."
        }
    }
}

/// Routes a conversion to the engine for its family. Returns the files it wrote.
enum ConversionEngine {
    static func convert(_ source: URL, to target: FileFormat, context: JobContext) async throws -> [URL] {
        guard let format = FileFormat.detect(source), FormatCompatibility.isSupported(format, target) else {
            throw ConversionError.unsupported(FileFormat.detect(source), target)
        }
        let settings = AppSettings.shared
        let options = settings.options(for: target)
        let outputs: [URL]
        switch (format.family, target.family) {
        case (.image, _):
            outputs = try await ImageConverter.convert(source, from: format, to: target, options: options, context: context)
        case (.document, _) where format == .pdf:
            outputs = try await DocumentConverter.convertPDF(source, to: target, context: context)
        case (.document, _) where format == .txt:
            outputs = try await DocumentConverter.convertText(source, to: target, context: context)
        case (.audio, _), (.video, _):
            outputs = try await MediaConverter.convert(source, from: format, to: target, options: options, context: context)
        case (.archive, _):
            outputs = try await ArchiveConverter.convert(source, from: format, to: target, options: options, context: context)
        case (.subtitle, _):
            outputs = try SubtitleConverter.convert(source, to: target)
        default:
            throw ConversionError.unsupported(format, target)
        }
        guard !outputs.isEmpty, outputs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ConversionError.noOutput
        }
        context.progress(1)
        return outputs
    }
}
