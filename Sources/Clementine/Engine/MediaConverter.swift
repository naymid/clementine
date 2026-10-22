import Foundation

/// Audio and video conversion through ffmpeg.
enum MediaConverter {
    static func convert(_ source: URL, from format: FileFormat, to target: FileFormat,
                        options: FormatOptions, context: JobContext) async throws -> [URL] {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw ProcessError.missingTool("ffmpeg") }
        let info = try await MediaInfo.probe(source)
        if target.family == .audio || target == .mp3 {
            guard info.hasAudio else { throw ProcessError.failed("This file has no audio track.") }
        }
        let output = FileNaming.output(beside: source, extension: target.outputExtension)
        var arguments = ["-y", "-hide_banner", "-nostdin", "-i", source.path]
        if target.family == .audio {
            arguments += ["-vn"] + audioArguments(for: target, options: options)
        } else if target == .gif {
            arguments += ["-an"] + gifArguments(info: info, options: options)
        } else {
            arguments += videoArguments(for: target, info: info, options: options, sourceIsGIF: format == .gif)
        }
        arguments += ["-map_metadata", "0", output.path]
        do {
            try await run(ffmpeg, arguments, duration: info.duration, context: context)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return [output]
    }

    static func run(_ ffmpeg: String, _ arguments: [String], duration: Double, context: JobContext,
                    progressRange: ClosedRange<Double> = 0...1) async throws {
        try await context.runner.run(ffmpeg, arguments) { line in
            guard duration > 0, let seconds = FFmpegProgress.seconds(in: line) else { return }
            let fraction = min(1, seconds / duration)
            context.progress(progressRange.lowerBound + fraction * (progressRange.upperBound - progressRange.lowerBound))
        }
    }

    static func audioArguments(for target: FileFormat, options: FormatOptions) -> [String] {
        let bitrate = "\(options.audioBitrate)k"
        switch target {
        case .mp3: return ["-c:a", "libmp3lame", "-b:a", bitrate]
        case .m4a: return ["-c:a", ToolPaths.ffmpegHasAudioToolbox ? "aac_at" : "aac", "-b:a", bitrate]
        case .wav: return ["-c:a", "pcm_s16le"]
        case .aiff: return ["-c:a", "pcm_s16be"]
        case .flac:
            let level: String
            switch options.compressionSpeed {
            case .faster: level = "2"
            case .balanced: level = "5"
            case .smallest: level = "8"
            }
            return ["-c:a", "flac", "-compression_level", level]
        case .ogg: return ["-c:a", "libvorbis", "-b:a", bitrate]
        case .opus: return ["-c:a", "libopus", "-b:a", "\(min(options.audioBitrate, 256))k", "-ar", "48000"]
        case .wma: return ["-c:a", "wmav2", "-b:a", "\(min(options.audioBitrate, 192))k"]
        default: return []
        }
    }

    /// Scale filter honoring the maximum height and the even sizes encoders need.
    static func scaleFilter(maxHeight: Int, info: MediaInfo) -> String {
        if maxHeight > 0, info.displaySize.height > CGFloat(maxHeight) {
            return "scale=-2:\(maxHeight)"
        }
        return "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    }

    static func videoArguments(for target: FileFormat, info: MediaInfo, options: FormatOptions, sourceIsGIF: Bool,
                               strengthBoost: Int = 0) -> [String] {
        let crf: Int
        switch options.quality {
        case .smaller: crf = 28
        case .balanced: crf = 23
        case .higher: crf = 18
        }
        let qscale: Int
        switch options.quality {
        case .smaller: qscale = 8
        case .balanced: qscale = 5
        case .higher: qscale = 3
        }
        var arguments: [String] = []
        let filter = scaleFilter(maxHeight: options.maxVideoHeight, info: info)
        if sourceIsGIF {
            arguments += ["-movflags", "+faststart"]
        }
        switch target {
        case .mp4, .mov, .mkv:
            arguments += ["-vf", filter, "-c:v", "libx264", "-preset", "medium", "-crf", "\(crf + strengthBoost)", "-pix_fmt", "yuv420p"]
            if target == .mov { arguments += ["-tag:v", "avc1"] }
            if target != .mkv { arguments += ["-movflags", "+faststart"] }
            arguments += info.hasAudio ? ["-c:a", "aac", "-b:a", "192k"] : ["-an"]
        case .webm:
            arguments += ["-vf", filter, "-c:v", "libvpx-vp9", "-crf", "\(crf + 8 + strengthBoost)", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
            arguments += info.hasAudio ? ["-c:a", "libopus", "-b:a", "160k"] : ["-an"]
        case .avi:
            arguments += ["-vf", filter, "-c:v", "mpeg4", "-vtag", "xvid", "-q:v", "\(qscale + strengthBoost / 3)"]
            arguments += info.hasAudio ? ["-c:a", "libmp3lame", "-b:a", "192k"] : ["-an"]
        case .wmv:
            arguments += ["-vf", filter, "-c:v", "wmv2", "-q:v", "\(qscale + strengthBoost / 3)"]
            arguments += info.hasAudio ? ["-c:a", "wmav2", "-b:a", "192k"] : ["-an"]
        case .mp3:
            let mp3 = AppSettings.shared.options(for: .mp3)
            arguments += ["-vn", "-c:a", "libmp3lame", "-b:a", "\(mp3.audioBitrate)k"]
        default:
            break
        }
        return arguments
    }

    static func gifArguments(info: MediaInfo, options: FormatOptions, strong: Bool = false) -> [String] {
        let width = min(options.gifMaxWidth, max(2, Int(info.displaySize.width)))
        let colors = strong ? 96 : 256
        let filter = "fps=\(options.gifFrameRate),scale=\(width):-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=\(colors):stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
        return ["-filter_complex", filter, "-loop", "0"]
    }
}

extension ToolPaths {
    static let ffmpegHasAudioToolbox: Bool = {
        guard let ffmpeg = ffmpeg else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("aac_at")
    }()
}
