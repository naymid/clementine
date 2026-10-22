import Foundation

enum MuteVideoProcessor {
    /// Copies the video stream untouched, drops the audio, and saves "<name>-muted.<ext>".
    static func mute(_ source: URL, context: JobContext) async throws -> URL {
        let info = try await VideoExport.probe(source)
        let output = VideoExport.output(for: source, suffix: "-muted")
        let arguments = ["-i", source.path, "-map", "0:V", "-c:v", "copy", "-an", "-map_metadata", "0"]
            + VideoExport.containerArguments(for: output)
        try await VideoExport.run(arguments, output: output, duration: info.duration, context: context)
        return output
    }
}
