import Foundation

enum FileNaming {
    /// The file name without its (possibly compound) extension.
    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        for compound in [".tar.gz", ".tgz"] where name.lowercased().hasSuffix(compound) {
            return String(name.dropLast(compound.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// A free URL beside `source`, e.g. "photo.png", then "photo 2.png".
    static func output(beside source: URL, suffix: String = "", extension ext: String) -> URL {
        let directory = source.deletingLastPathComponent()
        return uniqueURL(in: directory, base: baseName(of: source) + suffix, extension: ext)
    }

    static func uniqueURL(in directory: URL, base: String, extension ext: String) -> URL {
        let fm = FileManager.default
        func make(_ name: String) -> URL {
            ext.isEmpty ? directory.appendingPathComponent(name) : directory.appendingPathComponent("\(name).\(ext)")
        }
        var candidate = make(base)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = make("\(base) \(counter)")
            counter += 1
        }
        return candidate
    }

    /// A free folder URL beside `source`.
    static func folder(beside source: URL, suffix: String) -> URL {
        uniqueURL(in: source.deletingLastPathComponent(), base: baseName(of: source) + suffix, extension: "")
    }

    /// A scratch directory that is removed by the caller.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clementine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = bytes < 1000 ? [.useBytes] : [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    static func size(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0 ?? 0) } ?? 0
        }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func formatTime(_ seconds: Double, showsFraction: Bool = false) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let hours = minutes / 60
        let secs = total - Double(minutes * 60)
        if showsFraction {
            return hours > 0
                ? String(format: "%d:%02d:%05.2f", hours, minutes % 60, secs)
                : String(format: "%d:%05.2f", minutes, secs)
        }
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes % 60, Int(secs))
            : String(format: "%d:%02d", minutes, Int(secs))
    }
}
