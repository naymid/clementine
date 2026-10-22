import Foundation

enum ArchiveError: LocalizedError {
    case empty
    case unsupportedEntry(String)
    case extractFailed

    var errorDescription: String? {
        switch self {
        case .empty: return "The source archive is empty."
        case .unsupportedEntry(let name): return "RAR output cannot store \(name)."
        case .extractFailed: return "Could not extract the archive."
        }
    }
}

/// Repackages archives: extract to a scratch folder, then pack in the new format.
enum ArchiveConverter {
    static func convert(_ source: URL, from format: FileFormat, to target: FileFormat,
                        options: FormatOptions, context: JobContext) async throws -> [URL] {
        let scratch = try FileNaming.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let contents = scratch.appendingPathComponent("contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try await extract(source, format: format, into: contents, context: context)
        context.progress(0.5)
        let entries = try FileManager.default.contentsOfDirectory(atPath: contents.path).filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
        guard !entries.isEmpty else { throw ArchiveError.empty }
        let output = FileNaming.output(beside: source, extension: target.outputExtension)
        try await pack(entries: entries, in: contents, to: output, format: target, options: options, context: context)
        return [output]
    }

    static func extract(_ source: URL, format: FileFormat, into directory: URL, context: JobContext) async throws {
        switch format {
        case .zip:
            try await context.runner.run(ToolPaths.ditto, ["-x", "-k", source.path, directory.path])
        case .gzip:
            let name = source.lastPathComponent.lowercased()
            if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
                try await context.runner.run(ToolPaths.tar, ["-xzf", source.path, "-C", directory.path])
            } else {
                // A single gzipped file.
                let output = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent)
                let result = try await context.runner.run(ToolPaths.gzip, ["-dc", source.path])
                try result.stdout.write(to: output)
            }
        case .tar, .rar:
            // macOS's bsdtar (libarchive) reads tar and RAR (v4 and v5).
            do {
                try await context.runner.run(ToolPaths.tar, ["-xf", source.path, "-C", directory.path])
            } catch {
                guard format == .rar, let sevenZip = ToolPaths.find("7z") ?? ToolPaths.find("7zz") else { throw error }
                try await context.runner.run(sevenZip, ["x", "-y", "-o\(directory.path)", source.path])
            }
        default:
            throw ArchiveError.extractFailed
        }
    }

    static func pack(entries: [String], in directory: URL, to output: URL, format: FileFormat,
                     options: FormatOptions, context: JobContext) async throws {
        switch format {
        case .zip:
            let level: String
            switch options.compressionSpeed {
            case .faster: level = "-1"
            case .balanced: level = "-6"
            case .smallest: level = "-9"
            }
            try await context.runner.run("/usr/bin/zip", ["-r", "-q", "-y", level, output.path] + entries, currentDirectory: directory)
        case .tar:
            try await context.runner.run(ToolPaths.tar, ["-cf", output.path, "-C", directory.path] + entries)
        case .gzip:
            let level: Int
            switch options.compressionSpeed {
            case .faster: level = 1
            case .balanced: level = 6
            case .smallest: level = 9
            }
            try await context.runner.run(ToolPaths.tar, ["-czf", output.path, "--options", "gzip:compression-level=\(level)", "-C", directory.path] + entries)
        case .rar:
            try RAR5Writer.write(entries: entries, root: directory, to: output)
        default:
            throw ConversionError.unsupported(nil, format)
        }
    }
}

/// Writes RAR 5 archives using the "store" method (no compression),
/// so RAR output works without the proprietary rar tool.
enum RAR5Writer {
    private static let signature: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]

    static func write(entries: [String], root: URL, to output: URL) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: output) else { throw ArchiveError.extractFailed }
        defer { try? handle.close() }
        handle.write(Data(signature))
        // Main archive header: type 1, no flags, archive flags 0.
        handle.write(header(type: 1, flags: 0, body: vint(0)))

        var files: [(relative: String, url: URL)] = []
        for entry in entries {
            let url = root.appendingPathComponent(entry)
            files.append((entry, url))
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
               let enumerator = FileManager.default.enumerator(atPath: url.path) {
                // Path-based enumeration yields relative paths, immune to /private symlink prefixes.
                while let child = enumerator.nextObject() as? String {
                    files.append((entry + "/" + child, url.appendingPathComponent(child)))
                }
            }
        }

        for file in files where !file.relative.hasSuffix(".DS_Store") {
            let values = try file.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            if values.isSymbolicLink == true { throw ArchiveError.unsupportedEntry(file.relative) }
            let mtime = UInt32(max(0, (values.contentModificationDate ?? Date()).timeIntervalSince1970))
            let attributes = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int) ?? 0o644
            let name = Array(file.relative.utf8)
            if values.isDirectory == true {
                var body = Data()
                body += vint(0x0001 | 0x0002)          // directory, mtime present
                body += vint(0)                         // unpacked size
                body += vint(UInt64(0o040000 | attributes))
                body += uint32(mtime)
                body += vint(0)                         // compression info: stored
                body += vint(1)                         // host OS: Unix
                body += vint(UInt64(name.count)) + Data(name)
                // libarchive insists every file header carries a data area, even an empty one.
                handle.write(header(type: 2, flags: 0x0002, dataSize: 0, body: body))
            } else {
                let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
                let crc = CRC32.checksum(data)
                var body = Data()
                body += vint(0x0002 | 0x0004)          // mtime + CRC present
                body += vint(UInt64(data.count))       // unpacked size
                body += vint(UInt64(0o100000 | attributes))
                body += uint32(mtime)
                body += uint32(crc)
                body += vint(0)                         // version 0, method 0 (store)
                body += vint(1)                         // host OS: Unix
                body += vint(UInt64(name.count)) + Data(name)
                handle.write(header(type: 2, flags: 0x0002, dataSize: UInt64(data.count), body: body))
                handle.write(data)
            }
        }
        // End of archive header.
        handle.write(header(type: 5, flags: 0, body: vint(0)))
    }

    /// Builds a header block: CRC32, size, then [type, flags, (data size), body].
    private static func header(type: UInt64, flags: UInt64, dataSize: UInt64? = nil, body: Data) -> Data {
        var content = vint(type) + vint(flags)
        if let dataSize { content += vint(dataSize) }
        content += body
        let sized = vint(UInt64(content.count)) + content
        let crc = CRC32.checksum(sized)
        return uint32(crc) + sized
    }

    static func vint(_ value: UInt64) -> Data {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return Data(bytes)
    }

    static func uint32(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: 4)
    }
}

/// Standard CRC-32 (IEEE 802.3), as used by ZIP and RAR.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
