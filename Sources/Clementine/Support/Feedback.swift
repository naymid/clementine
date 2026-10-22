import AppKit
import AVFoundation

/// Sound and haptic feedback for petal highlights and finished jobs.
@MainActor
enum Feedback {
    private static var tickPlayer: AVAudioPlayer?
    private static var lastTick = Date.distantPast

    /// A short synthesized "tock" so no audio assets ship with the app.
    private static let tickData: Data = {
        let sampleRate = 44_100.0
        let duration = 0.045
        let count = Int(sampleRate * duration)
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let t = Double(index) / sampleRate
            let envelope = exp(-t * 95)
            let tone = sin(2 * .pi * 1_650 * t) * 0.55 + sin(2 * .pi * 2_900 * t) * 0.25
            samples[index] = Int16(max(-1, min(1, tone * envelope)) * 0.35 * Double(Int16.max))
        }
        return wav(samples: samples, sampleRate: Int(sampleRate))
    }()

    static func highlight() {
        guard AppSettings.shared.soundsAndHaptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        guard Date().timeIntervalSince(lastTick) > 0.03 else { return }
        lastTick = Date()
        if tickPlayer == nil {
            tickPlayer = try? AVAudioPlayer(data: tickData)
            tickPlayer?.volume = 0.45
            tickPlayer?.prepareToPlay()
        }
        tickPlayer?.currentTime = 0
        tickPlayer?.play()
    }

    static func drop() {
        guard AppSettings.shared.soundsAndHaptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    static func finished(success: Bool) {
        guard AppSettings.shared.soundsAndHaptics else { return }
        NSSound(named: success ? "Glass" : "Basso")?.play()
    }

    private static func wav(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        samples.forEach { append($0) }
        return data
    }
}
