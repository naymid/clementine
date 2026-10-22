import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lossless, byte-level metadata removal for containers ImageIO cannot rewrite
/// without re-encoding: PNG chunks, WebP RIFF chunks and HEIF/AVIF metadata items.
/// The compressed image data is never touched.
enum MetadataContainers {
    private static func fail() -> GeneralToolFailure { GeneralToolFailure("The image could not be verified. No output was saved.") }

    // MARK: PNG

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// Text, EXIF, timestamp and provenance chunks. Color chunks (iCCP, sRGB, gAMA, cHRM) stay.
    private static let pngMetadataChunks: Set<String> = ["tEXt", "zTXt", "iTXt", "eXIf", "tIME", "caBX"]

    static func stripPNG(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 8, Array(bytes[0..<8]) == pngSignature else { throw fail() }
        var output = Data(pngSignature)
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = Int(readBE32(bytes, offset))
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let total = 12 + length
            guard offset + total <= bytes.count else { throw fail() }
            if !pngMetadataChunks.contains(type) { output.append(contentsOf: bytes[offset..<(offset + total)]) }
            offset += total
            if type == "IEND" { break }
        }
        return output
    }

    // MARK: WebP

    private static let webPMetadataChunks: Set<String> = ["EXIF", "XMP "]

    private struct RIFFChunk {
        var fourCC: String
        var payload: [UInt8]
    }

    private static func webPChunks(_ bytes: [UInt8]) throws -> [RIFFChunk] {
        guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP" else { throw fail() }
        var chunks: [RIFFChunk] = []
        var offset = 12
        while offset + 8 <= bytes.count {
            let fourCC = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(readLE32(bytes, offset + 4))
            guard offset + 8 + size <= bytes.count else { throw fail() }
            chunks.append(RIFFChunk(fourCC: fourCC, payload: Array(bytes[(offset + 8)..<(offset + 8 + size)])))
            offset += 8 + size + (size & 1)
        }
        return chunks
    }

    private static func assembleWebP(_ chunks: [RIFFChunk]) -> Data {
        var body: [UInt8] = Array("WEBP".utf8)
        for chunk in chunks {
            body += Array(chunk.fourCC.utf8)
            body += le32(UInt32(chunk.payload.count))
            body += chunk.payload
            if chunk.payload.count & 1 == 1 { body.append(0) }
        }
        return Data(Array("RIFF".utf8) + le32(UInt32(body.count)) + body)
    }

    /// Removes the EXIF and XMP chunks and clears their VP8X flags.
    static func stripWebP(_ data: Data) throws -> Data {
        var chunks = try webPChunks([UInt8](data)).filter { !webPMetadataChunks.contains($0.fourCC) }
        if let index = chunks.firstIndex(where: { $0.fourCC == "VP8X" }), !chunks[index].payload.isEmpty {
            chunks[index].payload[0] &= ~UInt8(0x08 | 0x04)
        }
        return assembleWebP(chunks)
    }

    /// Replaces the WebP's EXIF and XMP chunks, adding a VP8X header to simple files when needed.
    static func webP(_ data: Data, exif: [UInt8]?, xmp: [UInt8]?, width: Int, height: Int, hasAlpha: Bool) throws -> Data {
        var chunks = try webPChunks([UInt8](data)).filter { !webPMetadataChunks.contains($0.fourCC) }
        if !chunks.contains(where: { $0.fourCC == "VP8X" }) {
            var payload = [UInt8](repeating: 0, count: 10)
            payload[0] = hasAlpha ? 0x10 : 0
            let w = UInt32(max(1, width) - 1), h = UInt32(max(1, height) - 1)
            payload[4] = UInt8(w & 0xFF); payload[5] = UInt8(w >> 8 & 0xFF); payload[6] = UInt8(w >> 16 & 0xFF)
            payload[7] = UInt8(h & 0xFF); payload[8] = UInt8(h >> 8 & 0xFF); payload[9] = UInt8(h >> 16 & 0xFF)
            chunks.insert(RIFFChunk(fourCC: "VP8X", payload: payload), at: 0)
        }
        guard let index = chunks.firstIndex(where: { $0.fourCC == "VP8X" }) else { throw fail() }
        chunks[index].payload[0] &= ~UInt8(0x08 | 0x04)
        if let exif, !exif.isEmpty {
            chunks.append(RIFFChunk(fourCC: "EXIF", payload: exif))
            chunks[index].payload[0] |= 0x08
        }
        if let xmp, !xmp.isEmpty {
            chunks.append(RIFFChunk(fourCC: "XMP ", payload: xmp))
            chunks[index].payload[0] |= 0x04
        }
        return assembleWebP(chunks)
    }

    // MARK: HEIF / AVIF

    private struct Box {
        var type: String
        var start: Int       // offset of the box header
        var contentStart: Int
        var end: Int
    }

    private static func boxes(_ bytes: [UInt8], from start: Int, to end: Int) throws -> [Box] {
        var result: [Box] = []
        var offset = start
        while offset + 8 <= end {
            var size = Int(readBE32(bytes, offset))
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            var header = 8
            if size == 1 {
                guard offset + 16 <= end else { throw fail() }
                size = Int(readBE64(bytes, offset + 8))
                header = 16
            } else if size == 0 {
                size = end - offset
            }
            guard size >= header, offset + size <= end else { throw fail() }
            result.append(Box(type: type, start: offset, contentStart: offset + header, end: offset + size))
            offset += size
        }
        return result
    }

    /// Wipes the Exif and XMP items of a HEIF/AVIF file in place: their bytes are zeroed and their
    /// item type renamed, so readers skip them. Returns how many items were removed.
    @discardableResult
    static func neutralizeHEIFMetadata(_ bytes: inout [UInt8]) throws -> Int {
        guard let meta = try boxes(bytes, from: 0, to: bytes.count).first(where: { $0.type == "meta" }) else { return 0 }
        let children = try boxes(bytes, from: meta.contentStart + 4, to: meta.end)
        var targets: [UInt32: Int] = [:] // item ID → offset of its item_type
        if let iinf = children.first(where: { $0.type == "iinf" }) {
            let version = bytes[iinf.contentStart]
            let entriesStart = iinf.contentStart + 4 + (version == 0 ? 2 : 4)
            for infe in try boxes(bytes, from: entriesStart, to: iinf.end) where infe.type == "infe" {
                let infeVersion = bytes[infe.contentStart]
                guard infeVersion >= 2 else { continue }
                var cursor = infe.contentStart + 4
                let itemID: UInt32
                if infeVersion == 2 { itemID = UInt32(readBE16(bytes, cursor)); cursor += 2 } else { itemID = readBE32(bytes, cursor); cursor += 4 }
                cursor += 2 // protection index
                guard cursor + 4 <= infe.end else { continue }
                let typeOffset = cursor
                let itemType = String(decoding: bytes[cursor..<(cursor + 4)], as: UTF8.self)
                cursor += 4
                if itemType == "Exif" {
                    targets[itemID] = typeOffset
                } else if itemType == "mime" {
                    // item_name, then content_type (both null-terminated).
                    while cursor < infe.end && bytes[cursor] != 0 { cursor += 1 }
                    cursor += 1
                    var contentType: [UInt8] = []
                    while cursor < infe.end && bytes[cursor] != 0 { contentType.append(bytes[cursor]); cursor += 1 }
                    let name = String(decoding: contentType, as: UTF8.self).lowercased()
                    if name.contains("rdf+xml") || name.contains("xmp") { targets[itemID] = typeOffset }
                }
            }
        }
        guard !targets.isEmpty else { return 0 }
        let idat = children.first(where: { $0.type == "idat" })
        if let iloc = children.first(where: { $0.type == "iloc" }) {
            var cursor = iloc.contentStart
            let version = bytes[cursor]
            cursor += 4
            let offsetSize = Int(bytes[cursor] >> 4), lengthSize = Int(bytes[cursor] & 0x0F)
            let baseOffsetSize = Int(bytes[cursor + 1] >> 4)
            let indexSize = (version == 1 || version == 2) ? Int(bytes[cursor + 1] & 0x0F) : 0
            cursor += 2
            let itemCount: Int
            if version < 2 { itemCount = Int(readBE16(bytes, cursor)); cursor += 2 } else { itemCount = Int(readBE32(bytes, cursor)); cursor += 4 }
            func readSized(_ size: Int) -> Int {
                defer { cursor += size }
                switch size {
                case 4: return Int(readBE32(bytes, cursor))
                case 8: return Int(readBE64(bytes, cursor))
                default: return 0
                }
            }
            for _ in 0..<itemCount {
                guard cursor < iloc.end else { throw fail() }
                let itemID: UInt32
                if version < 2 { itemID = UInt32(readBE16(bytes, cursor)); cursor += 2 } else { itemID = readBE32(bytes, cursor); cursor += 4 }
                var method = 0
                if version == 1 || version == 2 { method = Int(readBE16(bytes, cursor) & 0x0F); cursor += 2 }
                cursor += 2 // data reference index
                let baseOffset = readSized(baseOffsetSize)
                let extentCount = Int(readBE16(bytes, cursor))
                cursor += 2
                for _ in 0..<extentCount {
                    if indexSize > 0 { _ = readSized(indexSize) }
                    let extentOffset = readSized(offsetSize)
                    let extentLength = readSized(lengthSize)
                    guard targets[itemID] != nil, extentLength > 0 else { continue }
                    var start = baseOffset + extentOffset
                    if method == 1 {
                        guard let idat else { continue }
                        start += idat.contentStart
                    } else if method != 0 {
                        continue
                    }
                    guard start >= 0, start + extentLength <= bytes.count else { throw fail() }
                    for index in start..<(start + extentLength) { bytes[index] = 0 }
                }
            }
        }
        for offset in targets.values {
            bytes.replaceSubrange(offset..<(offset + 4), with: Array("free".utf8))
        }
        return targets.count
    }

    // MARK: EXIF/XMP blobs for WebP

    /// Serializes metadata to raw EXIF (TIFF-structured) and XMP packets by letting ImageIO
    /// write a JPEG of the same size, then lifting its APP1 segments.
    static func exifAndXMP(for metadata: CGImageMetadata, width: Int, height: Int) -> (exif: [UInt8]?, xmp: [UInt8]?) {
        guard let context = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage() else { return (nil, nil) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return (nil, nil) }
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, [kCGImageDestinationLossyCompressionQuality: 0.1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return (nil, nil) }
        let bytes = [UInt8](data as Data)
        var exif: [UInt8]?, xmp: [UInt8]?
        var offset = 2
        let exifHeader = Array("Exif".utf8) + [0, 0]
        let xmpHeader = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0]
        while offset + 4 <= bytes.count, bytes[offset] == 0xFF {
            let marker = bytes[offset + 1]
            if marker == 0xDA || marker == 0xD9 { break }
            let length = Int(readBE16(bytes, offset + 2))
            let payloadStart = offset + 4, payloadEnd = offset + 2 + length
            guard payloadEnd <= bytes.count else { break }
            if marker == 0xE1 {
                let payload = Array(bytes[payloadStart..<payloadEnd])
                if payload.starts(with: exifHeader) { exif = Array(payload.dropFirst(exifHeader.count)) }
                if payload.starts(with: xmpHeader) { xmp = Array(payload.dropFirst(xmpHeader.count)) }
            }
            offset = payloadEnd
        }
        return (exif, xmp)
    }

    // MARK: Byte helpers

    static func readBE16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func readBE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    static func readBE64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(readBE32(bytes, offset)) << 32 | UInt64(readBE32(bytes, offset + 4))
    }

    static func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
    }
}
