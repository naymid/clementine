import Foundation

/// Locates the command-line tools Clementine drives.
enum ToolPaths {
    private static let searchDirectories: [String] = {
        var dirs: [String] = []
        if let tools = Bundle.main.resourceURL?.appendingPathComponent("Tools").path { dirs.append(tools) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin"]
        return dirs
    }()

    static func find(_ name: String) -> String? {
        for dir in searchDirectories {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static var ffmpeg: String? { find("ffmpeg") }
    static var ffprobe: String? { find("ffprobe") }
    static var cwebp: String? { find("cwebp") }
    static var exiftool: String? { find("exiftool") }
    static var tar: String { find("tar") ?? "/usr/bin/tar" }
    static var gzip: String { find("gzip") ?? "/usr/bin/gzip" }
    static var ditto: String { "/usr/bin/ditto" }
}

enum ProcessError: LocalizedError {
    case missingTool(String)
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingTool(let name): return "\(name) is required for this conversion. Install it with Homebrew: brew install \(name)"
        case .failed(let message): return message
        case .cancelled: return "Cancelled."
        }
    }
}

/// Runs external processes asynchronously, optionally streaming stderr lines.
final class ProcessRunner: @unchecked Sendable {
    private var process: Process?
    private let lock = NSLock()
    private(set) var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    @discardableResult
    func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil,
             onStderrLine: ((String) -> Void)? = nil) async throws -> (stdout: Data, stderr: String) {
        if isCancelled { throw ProcessError.cancelled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let stdoutBuffer = DataBuffer()
        let stderrBuffer = DataBuffer()
        let lineSplitter = LineSplitter(handler: onStderrLine)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stdoutBuffer.append(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrBuffer.append(data)
                lineSplitter.feed(data)
            }
        }

        lock.lock()
        self.process = process
        lock.unlock()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(errPipe.fileHandleForReading.readDataToEndOfFile())

        if isCancelled { throw ProcessError.cancelled }
        let stderrText = String(decoding: stderrBuffer.data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let lastLines = stderrText.split(separator: "\n").suffix(4).joined(separator: "\n")
            throw ProcessError.failed(lastLines.isEmpty ? "The conversion process failed." : lastLines)
        }
        return (stdoutBuffer.data, stderrText)
    }
}

private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }
}

private final class LineSplitter: @unchecked Sendable {
    private var pending = ""
    private let handler: ((String) -> Void)?
    private let lock = NSLock()
    init(handler: ((String) -> Void)?) { self.handler = handler }
    func feed(_ data: Data) {
        guard let handler else { return }
        lock.lock()
        pending += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let range = pending.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n")) {
            lines.append(String(pending[..<range.lowerBound]))
            pending.removeSubrange(..<range.upperBound)
        }
        lock.unlock()
        lines.filter { !$0.isEmpty }.forEach(handler)
    }
}

/// Media facts read with ffprobe.
struct MediaInfo {
    var duration: Double = 0
    var width = 0
    var height = 0
    var frameRate: Double = 30
    var hasVideo = false
    var hasAudio = false
    var audioChannelCount = 0
    var videoCodec = ""
    var audioCodec = ""
    var videoBitRate = 0
    var rotation = 0

    var displaySize: CGSize {
        rotation % 180 == 0 ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
    }

    static func probe(_ url: URL) async throws -> MediaInfo {
        guard let ffprobe = ToolPaths.ffprobe else { throw ProcessError.missingTool("ffmpeg") }
        let result = try await ProcessRunner().run(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        guard let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else { return MediaInfo() }
        var info = MediaInfo()
        if let format = json["format"] as? [String: Any], let duration = format["duration"] as? String {
            info.duration = Double(duration) ?? 0
        }
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let type = stream["codec_type"] as? String
            if type == "video", !info.hasVideo {
                let disposition = stream["disposition"] as? [String: Any]
                if (disposition?["attached_pic"] as? Int) == 1 { continue }
                info.hasVideo = true
                info.width = stream["width"] as? Int ?? 0
                info.height = stream["height"] as? Int ?? 0
                info.videoCodec = stream["codec_name"] as? String ?? ""
                info.videoBitRate = Int(stream["bit_rate"] as? String ?? "") ?? 0
                if let rate = stream["avg_frame_rate"] as? String ?? stream["r_frame_rate"] as? String {
                    let parts = rate.split(separator: "/").compactMap { Double($0) }
                    if parts.count == 2, parts[1] > 0, parts[0] > 0 { info.frameRate = parts[0] / parts[1] }
                }
                if let sideData = stream["side_data_list"] as? [[String: Any]] {
                    for item in sideData { if let rotation = item["rotation"] as? Int { info.rotation = abs(rotation) % 360 } }
                }
                if let tags = stream["tags"] as? [String: Any], let rotate = tags["rotate"] as? String, let value = Int(rotate) {
                    info.rotation = abs(value) % 360
                }
                if info.duration == 0, let duration = stream["duration"] as? String { info.duration = Double(duration) ?? 0 }
            } else if type == "audio", !info.hasAudio {
                info.hasAudio = true
                info.audioChannelCount = stream["channels"] as? Int ?? 0
                info.audioCodec = stream["codec_name"] as? String ?? ""
                if info.duration == 0, let duration = stream["duration"] as? String { info.duration = Double(duration) ?? 0 }
            }
        }
        return info
    }
}

/// Parses ffmpeg's "time=00:00:12.34" progress output.
enum FFmpegProgress {
    static func seconds(in line: String) -> Double? {
        guard let range = line.range(of: "time=") else { return nil }
        let value = line[range.upperBound...].prefix { $0 != " " }
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}
