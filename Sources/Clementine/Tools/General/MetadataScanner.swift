import Foundation

/// What kinds of private or identifying data a file carries.
struct PrivacyFindings: OptionSet, Hashable {
    let rawValue: Int
    static let location = PrivacyFindings(rawValue: 1 << 0)
    static let camera = PrivacyFindings(rawValue: 1 << 1)
    static let author = PrivacyFindings(rawValue: 1 << 2)
    static let aiTags = PrivacyFindings(rawValue: 1 << 3)
    static let contentCredentials = PrivacyFindings(rawValue: 1 << 4)
    static let prompt = PrivacyFindings(rawValue: 1 << 5)

    /// Labels in display order.
    var labels: [(PrivacyFindings, String)] {
        let all: [(PrivacyFindings, String)] = [
            (.location, "Location"), (.camera, "Camera"), (.author, "Author"),
            (.aiTags, "AI tags"), (.contentCredentials, "Content Credentials"), (.prompt, "Prompt"),
        ]
        return all.filter { contains($0.0) }
    }
}

/// One file's scan: findings plus how many readable fields it has.
struct MetadataScan {
    var findings: PrivacyFindings = []
    var fieldCount = 0
    var hasAnything: Bool { !findings.isEmpty || fieldCount > 0 }
}

/// Finds AI-generation markers, C2PA Content Credentials and generation prompts by
/// reading the file's bytes, since ImageIO doesn't surface most of them. Also used
/// to check cleaned files before they are saved.
enum MetadataScanner {
    /// Large files (video) are scanned at both ends, where container metadata lives.
    private static let windowSize = 8 * 1024 * 1024

    private static let aiMarkers: [String] = [
        "algorithmicMedia",          // IPTC DigitalSourceType: trainedAlgorithmicMedia, compositeWith…
        "Made with Google AI", "Midjourney", "DALL-E", "DALL\u{00B7}E", "Stable Diffusion",
        "Adobe Firefly", "OpenAI", "Imagen", "NovelAI", "InvokeAI", "ComfyUI", "Leonardo.Ai", "Ideogram",
    ]

    private static let promptMarkers: [String] = [
        "tEXtparameters", "iTXtparameters", "tEXtprompt", "iTXtprompt", "tEXtworkflow", "iTXtworkflow",
        "sd-metadata", "invokeai_metadata", "Negative prompt:",
    ]

    /// The ISO BMFF 'uuid' usertype that carries a C2PA manifest store (MP4, MOV, HEIF, AVIF).
    private static let c2paBoxUUID: [UInt8] = [0xD8, 0xFE, 0xC3, 0xD6, 0x1B, 0x0E, 0x48, 0x3C,
                                               0x92, 0x97, 0x58, 0x28, 0x87, 0x7E, 0xC4, 0x81]

    static func bytes(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        try? handle.seek(toOffset: 0)
        if size <= windowSize * 2 { return (try? handle.readToEnd()) ?? Data() }
        var data = (try? handle.read(upToCount: windowSize)) ?? Data()
        try? handle.seek(toOffset: UInt64(size - windowSize))
        data.append((try? handle.readToEnd()) ?? Data())
        return data
    }

    /// AI tags, Content Credentials and prompts found in raw bytes.
    static func markers(in data: Data) -> PrivacyFindings {
        var found: PrivacyFindings = []
        func has(_ text: String) -> Bool { data.range(of: Data(text.utf8)) != nil }
        if aiMarkers.contains(where: has) { found.insert(.aiTags) }
        if promptMarkers.contains(where: has) || (has("Steps: ") && has("Sampler: ")) { found.insert(.prompt) }
        // Every C2PA container wraps a JUMBF superbox, so require that structure: a bare
        // 4-byte tag can turn up by chance inside compressed image data.
        if has("jumdc2pa")                                           // JUMBF description box, C2PA type UUID (JPEG APP11 and others)
            || tag("caBX", followedBy: "jumb", at: 8, in: data)       // PNG chunk
            || tag("C2PA", followedBy: "jumb", at: 12, in: data)      // WebP RIFF chunk
            || data.range(of: Data(c2paBoxUUID)) != nil {             // ISO BMFF uuid box
            found.insert(.contentCredentials)
        }
        return found
    }

    /// True when some occurrence of `tag` has `next` exactly `offset` bytes after its start.
    private static func tag(_ tag: String, followedBy next: String, at offset: Int, in data: Data) -> Bool {
        let tagBytes = Data(tag.utf8), nextBytes = Data(next.utf8)
        var searchStart = data.startIndex
        while let range = data.range(of: tagBytes, in: searchStart..<data.endIndex) {
            let candidate = range.lowerBound + offset
            if candidate + nextBytes.count <= data.endIndex, data[candidate..<(candidate + nextBytes.count)] == nextBytes { return true }
            searchStart = range.upperBound
        }
        return false
    }

    /// Classifies readable fields into the same categories.
    static func findings(from report: MetadataReport) -> PrivacyFindings {
        var found: PrivacyFindings = []
        for field in report.fields {
            let key = (field.id + " " + field.label).lowercased()
            if field.section == "GPS Location" || key.contains("gps") || key.contains("location") || key.contains("iso6709") {
                found.insert(.location)
            }
            if ["make", "model", "serial", "lens", "camera"].contains(where: key.contains) { found.insert(.camera) }
            // "CreatorTool" is the software that made the file, not a person.
            if ["artist", "creator", "owner", "author", "copyright", "byline"].contains(where: key.contains), !key.contains("creatortool") {
                found.insert(.author)
            }
            let value = field.value
            if aiMarkers.contains(where: { value.localizedCaseInsensitiveContains($0) }) { found.insert(.aiTags) }
        }
        return found
    }

    /// Full scan of one file: readable fields plus byte markers.
    static func scan(_ url: URL) async -> MetadataScan {
        var scan = MetadataScan()
        if let report = try? await MetadataStore.read(url) {
            scan.fieldCount = report.fields.filter(\.removable).count
            scan.findings = findings(from: report)
        }
        scan.findings.formUnion(markers(in: bytes(of: url)))
        return scan
    }

    /// Throws if a cleaned file still carries any of the given kinds of data.
    static func verifyStripped(_ output: URL, name: String, checking kinds: PrivacyFindings) throws {
        let leftovers = markers(in: bytes(of: output)).intersection(kinds)
        guard let first = leftovers.labels.first else { return }
        throw GeneralToolFailure("\(first.1) remained in \(name); no output was saved.")
    }
}
