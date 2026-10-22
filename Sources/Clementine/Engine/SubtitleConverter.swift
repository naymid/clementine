import Foundation

enum SubtitleError: LocalizedError {
    case noCues
    case empty

    var errorDescription: String? {
        switch self {
        case .noCues: return "No valid subtitle cues were found."
        case .empty: return "The text file has no subtitle content."
        }
    }
}

/// Converts between SRT, WebVTT and plain text.
enum SubtitleConverter {
    struct Cue: Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    static func convert(_ source: URL, to target: FileFormat) throws -> [URL] {
        let text = try DocumentConverter.readText(source)
        let sourceFormat = FileFormat.detect(source)
        var cues = parse(text)
        if cues.isEmpty {
            guard sourceFormat == .txt else { throw SubtitleError.noCues }
            cues = cuesFromPlainText(text)
            guard !cues.isEmpty else { throw SubtitleError.empty }
        }
        let output = FileNaming.output(beside: source, extension: target.outputExtension)
        let rendered: String
        switch target {
        case .srt: rendered = srt(cues)
        case .vtt: rendered = vtt(cues)
        case .txt: rendered = cues.map(\.text).joined(separator: "\n") + "\n"
        default: throw ConversionError.unsupported(sourceFormat, target)
        }
        try rendered.write(to: output, atomically: true, encoding: .utf8)
        return [output]
    }

    /// Parses SRT or WebVTT cues.
    static func parse(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [Cue] = []
        for block in blocks {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timestamp(parts[0]),
                  let end = timestamp(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(Cue(start: start, end: max(end, start), text: body))
        }
        return cues
    }

    static func timestamp(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let numbers = parts.compactMap(Double.init)
        guard numbers.count == parts.count else { return nil }
        return numbers.count == 3 ? numbers[0] * 3600 + numbers[1] * 60 + numbers[2] : numbers[0] * 60 + numbers[1]
    }

    /// One cue per non-empty line, timed by reading speed.
    static func cuesFromPlainText(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        var time = 0.0
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let words = trimmed.split(separator: " ").count
            let duration = min(7, max(1.5, Double(words) * 0.38))
            cues.append(Cue(start: time, end: time + duration, text: trimmed))
            time += duration
        }
        return cues
    }

    static func format(_ seconds: Double, separator: Character) -> String {
        let millis = Int((seconds * 1000).rounded())
        let h = millis / 3_600_000, m = (millis / 60_000) % 60, s = (millis / 1000) % 60, ms = millis % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, String(separator), ms)
    }

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(format(cue.start, separator: ",")) --> \(format(cue.end, separator: ","))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(format(cue.start, separator: ".")) --> \(format(cue.end, separator: "."))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }
}
